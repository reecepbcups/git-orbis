// Command orbis-filter is git's long running filter process for git-orbis,
// the same setup git-lfs uses. git starts it once per command and streams
// every file through it, so a plain file costs a pipe round trip instead of a
// bash process. Files that really need encrypting or decrypting go to the
// git-orbis script, which stays the source of truth for access.
//
//	git config filter.orbis.process "orbis-filter /path/to/bin/git-orbis"
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"slices"
	"strings"
)

func main() {
	os.Exit(run())
}

func run() int {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil)).With("prog", "orbis-filter")
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: orbis-filter <path to git-orbis>")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	f := &filter{script: os.Args[1]}
	defer f.close()
	if err := serve(ctx, f, bufio.NewReader(os.Stdin), bufio.NewWriter(os.Stdout), log); err != nil {
		log.Error("filter stopped", "err", err)
		return 1
	}
	return 0
}

// applier turns one file's content into what git should store or check out.
type applier interface {
	apply(ctx context.Context, req request) ([]byte, error)
}

// request is one file git asked us to filter.
type request struct {
	command string // clean or smudge
	path    string
	content []byte
}

// serve runs the handshake, then answers requests until git closes stdin.
func serve(ctx context.Context, a applier, r *bufio.Reader, w *bufio.Writer, log *slog.Logger) error {
	if err := handshake(r, w); err != nil {
		return fmt.Errorf("handshake: %w", err)
	}
	for {
		hdr, err := readText(r)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read request: %w", err)
		}
		req := request{}
		for _, l := range hdr {
			k, v, _ := strings.Cut(l, "=")
			switch k {
			case "command":
				req.command = v
			case "pathname":
				req.path = v
			}
		}
		if req.content, err = readContent(r); err != nil {
			return fmt.Errorf("read %s content: %w", req.path, err)
		}

		out, err := a.apply(ctx, req)
		if err != nil {
			// git aborts since filter.orbis.required is true
			log.Error("filter file", "command", req.command, "path", req.path, "err", err)
			if err := writeText(w, "status=error"); err != nil {
				return err
			}
		} else if err := respond(w, out); err != nil {
			return err
		}
		if err := w.Flush(); err != nil {
			return fmt.Errorf("write response: %w", err)
		}
	}
}

func respond(w io.Writer, out []byte) error {
	if err := writeText(w, "status=success"); err != nil {
		return err
	}
	if err := writeContent(w, out); err != nil {
		return err
	}
	// empty list keeps status=success
	return writeFlush(w)
}

func handshake(r *bufio.Reader, w *bufio.Writer) error {
	hello, err := readText(r)
	if err != nil {
		return err
	}
	if !slices.Contains(hello, "git-filter-client") || !slices.Contains(hello, "version=2") {
		return fmt.Errorf("unexpected hello %q", hello)
	}
	if err := writeText(w, "git-filter-server", "version=2"); err != nil {
		return err
	}
	if err := w.Flush(); err != nil {
		return err
	}
	offered, err := readText(r)
	if err != nil {
		return err
	}
	var caps []string
	for _, c := range []string{"capability=clean", "capability=smudge"} {
		if slices.Contains(offered, c) {
			caps = append(caps, c)
		}
	}
	if err := writeText(w, caps...); err != nil {
		return err
	}
	return w.Flush()
}
