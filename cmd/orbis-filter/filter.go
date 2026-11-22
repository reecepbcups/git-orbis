package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// magic is the first line of every pointer git-orbis commits.
const magic = "orbis-git v1"

// pointerMax is bigger than any pointer, so larger blobs skip the content read.
const pointerMax = 256

// filter decides which files are plain and passes those straight back.
// it mirrors protected() in bin/git-orbis and must never pass through a file
// that the script would encrypt.
type filter struct {
	script string

	loaded   bool
	hasRules bool
	attrs    string // temp attributes file built from .orbis/access
	checkRun *coproc
	catFile  *coproc
}

func (f *filter) apply(ctx context.Context, req request) ([]byte, error) {
	switch req.command {
	case "smudge":
		if !isPointer(req.content) {
			return req.content, nil
		}
		return f.runScript(ctx, req)
	case "clean":
		if isPointer(req.content) {
			return req.content, nil
		}
		p, err := f.protected(ctx, req.path)
		if err != nil {
			return nil, fmt.Errorf("check %s: %w", req.path, err)
		}
		if !p {
			return req.content, nil
		}
		return f.runScript(ctx, req)
	}
	return nil, fmt.Errorf("unknown command %q", req.command)
}

func isPointer(b []byte) bool {
	line, _, _ := bytes.Cut(b, []byte("\n"))
	return string(line) == magic
}

// protected reports whether path should be encrypted. same rules as the script:
// covered by .orbis/access, no access file at all (old repos), or git already
// holds a pointer for it.
func (f *filter) protected(ctx context.Context, path string) (bool, error) {
	if path == ".gitattributes" || strings.HasPrefix(path, ".orbis/") {
		return false, nil
	}
	// odd paths break the line based coprocs, let the script decide
	if path == "" || strings.ContainsAny(path, "\n\x00") {
		return true, nil
	}
	if err := f.load(ctx); err != nil {
		return false, err
	}
	if !f.hasRules {
		return true, nil
	}
	matched, err := f.matches(path)
	if err != nil || matched {
		return matched, err
	}
	return f.indexPointer(path)
}

// load reads .orbis/access once per git command and starts the coprocs.
func (f *filter) load(ctx context.Context) error {
	if f.loaded {
		return nil
	}
	f.loaded = true
	src, err := repoFile(ctx, ".orbis/access")
	if err != nil {
		return err
	}
	pats := accessPatterns(src)
	if len(pats) == 0 {
		return nil
	}
	f.hasRules = true

	tmp, err := os.CreateTemp("", "orbis-attrs-*")
	if err != nil {
		return fmt.Errorf("attrs file: %w", err)
	}
	f.attrs = tmp.Name()
	var buf strings.Builder
	for _, p := range pats {
		buf.WriteString(p + " orbis-rule\n")
	}
	_, err = tmp.WriteString(buf.String())
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fmt.Errorf("write attrs: %w", err)
	}
	// git does the matching so it agrees with .gitattributes
	if f.checkRun, err = startCoproc(ctx, "-c", "core.attributesFile="+f.attrs, "check-attr", "--stdin", "-z", "orbis-rule"); err != nil {
		return err
	}
	if f.catFile, err = startCoproc(ctx, "cat-file", "--batch-command"); err != nil {
		return err
	}
	return nil
}

// accessPatterns pulls the pattern column out of .orbis/access.
// branch: rules are for push-private, not files.
func accessPatterns(src []byte) []string {
	var pats []string
	for l := range strings.SplitSeq(string(src), "\n") {
		fields := strings.Fields(l)
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") || strings.HasPrefix(fields[0], "branch:") {
			continue
		}
		pats = append(pats, fields[0])
	}
	return pats
}

func (f *filter) matches(path string) (bool, error) {
	c := f.checkRun
	if _, err := io.WriteString(c.in, path+"\x00"); err != nil {
		return false, err
	}
	// output is path NUL attr NUL value NUL
	var val string
	for range 3 {
		s, err := c.out.ReadString(0)
		if err != nil {
			return false, fmt.Errorf("check-attr: %w", err)
		}
		val = strings.TrimSuffix(s, "\x00")
	}
	return val == "set", nil
}

// indexPointer reports whether the index already stores path as a pointer.
func (f *filter) indexPointer(path string) (bool, error) {
	c := f.catFile
	if _, err := fmt.Fprintf(c.in, "info :%s\n", path); err != nil {
		return false, err
	}
	line, err := c.out.ReadString('\n')
	if err != nil {
		return false, fmt.Errorf("cat-file: %w", err)
	}
	// "<oid> <type> <size>" or "<obj> missing"
	fields := strings.Fields(line)
	if len(fields) != 3 {
		return false, nil
	}
	size, err := strconv.Atoi(fields[2])
	if err != nil {
		return false, fmt.Errorf("cat-file size %q: %w", line, err)
	}
	if fields[1] != "blob" || size > pointerMax {
		return false, nil
	}
	if _, err := fmt.Fprintf(c.in, "contents %s\n", fields[0]); err != nil {
		return false, err
	}
	if _, err := c.out.ReadString('\n'); err != nil {
		return false, err
	}
	body := make([]byte, size+1) // trailing newline
	if _, err := io.ReadFull(c.out, body); err != nil {
		return false, fmt.Errorf("cat-file contents: %w", err)
	}
	return isPointer(body[:size]), nil
}

// runScript hands one file to git-orbis clean|smudge, the slow path.
func (f *filter) runScript(ctx context.Context, req request) ([]byte, error) {
	cmd := exec.CommandContext(ctx, f.script, req.command, req.path)
	cmd.Stdin = bytes.NewReader(req.content)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git-orbis %s %s: %w", req.command, req.path, err)
	}
	return out, nil
}

func (f *filter) close() {
	for _, c := range []*coproc{f.checkRun, f.catFile} {
		if c != nil {
			c.close()
		}
	}
	if f.attrs != "" {
		_ = os.Remove(f.attrs) // temp file, nothing to do if it's already gone
	}
}

// repoFile reads path from the worktree, or from the index/HEAD mid-checkout.
func repoFile(ctx context.Context, path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err == nil || !errors.Is(err, os.ErrNotExist) {
		return b, err
	}
	for _, rev := range []string{":" + path, "HEAD:" + path} {
		if b, err := exec.CommandContext(ctx, "git", "show", rev).Output(); err == nil {
			return b, nil
		}
	}
	return nil, nil
}

// coproc is a git process we talk to line by line for the whole command.
type coproc struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
}

func startCoproc(ctx context.Context, args ...string) (*coproc, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	// flush after every answer, we wait on each one
	cmd.Env = append(os.Environ(), "GIT_FLUSH=1")
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start git %s: %w", args, err)
	}
	return &coproc{cmd: cmd, in: in, out: bufio.NewReader(out)}, nil
}

func (c *coproc) close() {
	// closing stdin ends the git process, its exit status doesn't matter by now
	_ = c.in.Close()
	_ = c.cmd.Wait()
}
