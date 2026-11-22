package main

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestIsPointer(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want bool
	}{
		{"pointer", "orbis-git v1\nobject: abc\n", true},
		{"no trailing newline", "orbis-git v1", true},
		{"plain", "SECRET=1\n", false},
		{"magic later", "x\norbis-git v1\n", false},
		{"empty", "", false},
		{"binary", "\x00\x01orbis-git v1", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := isPointer([]byte(tt.in)); got != tt.want {
				t.Fatalf("isPointer(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}

func TestAccessPatterns(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"empty", "", nil},
		{"comments and blanks", "# hi\n\n  # indented\n", nil},
		{"rules", ".env*  @all\n.env.production @ops did:key:z\n", []string{".env*", ".env.production"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := accessPatterns([]byte(tt.in)); !slices.Equal(got, tt.want) {
				t.Fatalf("accessPatterns = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestPktRoundTrip(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		size int
	}{
		{"empty", 0},
		{"small", 10},
		{"one packet", maxPktData},
		{"split", maxPktData*2 + 7},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			data := bytes.Repeat([]byte("a"), tt.size)
			var buf bytes.Buffer
			if err := writeContent(&buf, data); err != nil {
				t.Fatal(err)
			}
			got, err := readContent(bufio.NewReader(&buf))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, data) {
				t.Fatalf("got %d bytes, want %d", len(got), len(data))
			}
		})
	}
}

// TestGit runs real git commands through the built filter, with a fake
// git-orbis that "encrypts" by writing a pointer and "decrypts" to DECRYPTED.
func TestGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "orbis-filter")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	script := filepath.Join(dir, "git-orbis")
	writeFile(t, script, `#!/bin/sh
cat >/dev/null
case "$1" in
  clean) printf 'orbis-git v1\nobject: %s\n' "$2" ;;
  smudge) echo DECRYPTED ;;
esac
`)
	if err := os.Chmod(script, 0o755); err != nil {
		t.Fatal(err)
	}

	repo := filepath.Join(dir, "repo")
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t"}, args...)...)
		cmd.Dir = repo
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %s: %v\n%s", args, err, out)
		}
		return string(out)
	}
	if err := os.MkdirAll(filepath.Join(repo, ".orbis"), 0o755); err != nil {
		t.Fatal(err)
	}
	git("init", "-q")
	git("config", "filter.orbis.process", bin+" "+script)
	git("config", "filter.orbis.required", "true")
	writeFile(t, filepath.Join(repo, ".gitattributes"), "* filter=orbis\n")
	writeFile(t, filepath.Join(repo, ".orbis/access"), ".env*  @all\nsub/*.key @ops\n")
	writeFile(t, filepath.Join(repo, ".env"), "SECRET=1\n")
	writeFile(t, filepath.Join(repo, ".env.prod"), "SECRET=2\n")
	writeFile(t, filepath.Join(repo, "README.md"), "hello\n")
	if err := os.MkdirAll(filepath.Join(repo, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(repo, "sub/a.key"), "KEY\n")
	git("add", "-A")
	git("commit", "-qm", "init")

	stored := map[string]bool{".env": true, ".env.prod": true, "sub/a.key": true, "README.md": false, ".orbis/access": false}
	for path, wantPtr := range stored {
		if got := isPointer([]byte(git("show", ":"+path))); got != wantPtr {
			t.Errorf("%s stored as pointer = %v, want %v", path, got, wantPtr)
		}
	}

	// dropping a rule must not downgrade an encrypted file to plaintext
	writeFile(t, filepath.Join(repo, ".orbis/access"), ".env  @all\n")
	writeFile(t, filepath.Join(repo, "sub/a.key"), "KEY2\n")
	git("add", "-A")
	if !isPointer([]byte(git("show", ":sub/a.key"))) {
		t.Error("sub/a.key went plaintext after its rule was removed")
	}
	git("commit", "-qm", "drop rule")

	for _, p := range []string{".env", "README.md"} {
		if err := os.Remove(filepath.Join(repo, p)); err != nil {
			t.Fatal(err)
		}
	}
	git("checkout", "--", ".")
	if got := readFile(t, filepath.Join(repo, ".env")); got != "DECRYPTED\n" {
		t.Errorf(".env after checkout = %q", got)
	}
	if got := readFile(t, filepath.Join(repo, "README.md")); got != "hello\n" {
		t.Errorf("README.md after checkout = %q", got)
	}
	if s := git("status", "--porcelain"); strings.Contains(s, "README") {
		t.Errorf("README dirty: %s", s)
	}
}

func writeFile(t *testing.T, path, s string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
