package sys

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWithExtraPath(t *testing.T) {
	old := extraPath
	extraPath = []string{"/opt/homebrew/bin", "/usr/local/bin"}
	defer func() { extraPath = old }()

	cases := []struct{ name, in, want string }{
		{"empty becomes the system folders plus the extras", "", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"},
		{"a Finder-style path gets both", "/usr/bin:/bin:/usr/sbin:/sbin", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"},
		{"only what is missing is added", "/opt/homebrew/bin:/usr/bin", "/opt/homebrew/bin:/usr/bin:/usr/local/bin"},
		{"nothing to add keeps the order", "/usr/local/bin:/usr/bin:/opt/homebrew/bin", "/usr/local/bin:/usr/bin:/opt/homebrew/bin"},
		{"empty elements (the current folder) are dropped", "/usr/bin::/bin:", "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"},
		{"the extras go after the existing folders, never before", "/home/me/bin:/usr/bin", "/home/me/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin"},
	}
	for _, c := range cases {
		if got := withExtraPath(c.in); got != c.want {
			t.Errorf("%s: withExtraPath(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func writeTool(t *testing.T, dir, name, body string, mode os.FileMode) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLookPath(t *testing.T) {
	a, b := filepath.Join(t.TempDir(), "a"), filepath.Join(t.TempDir(), "b")
	toolA := writeTool(t, a, "tool", "#!/bin/sh\n", 0o755)
	writeTool(t, b, "tool", "#!/bin/sh\n", 0o755)
	writeTool(t, b, "plain", "not executable", 0o644)
	if err := os.MkdirAll(filepath.Join(b, "adir"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := a + ":" + b

	if got, err := lookPath("tool", path); err != nil || got != toolA {
		t.Errorf("the first folder with the tool wins: %q, %v (want %q)", got, err, toolA)
	}
	for _, name := range []string{"plain", "adir", "missing-xyz"} {
		_, err := lookPath(name, path)
		var ee *exec.Error
		if !errors.As(err, &ee) || !errors.Is(err, exec.ErrNotFound) {
			t.Errorf("%s: want an exec not-found error, got %v", name, err)
		}
	}
	if got, err := lookPath("/bin/sh", ""); err != nil || got != "/bin/sh" {
		t.Errorf("a name with a slash is used as it is: %q, %v", got, err)
	}
}

func TestLookPath_NeverSearchesTheCurrentFolder(t *testing.T) {
	here := t.TempDir()
	writeTool(t, here, "sneaky", "#!/bin/sh\n", 0o755)
	t.Chdir(here)
	for _, path := range []string{"", ":", "/nonexistent:", ".", "/nonexistent:."} {
		if got, err := lookPath("sneaky", path); err == nil {
			t.Errorf("PATH %q found %q in the current folder", path, got)
		}
	}
}

func TestExecRunner_FindsToolsInTheExtraFoldersAndPassesThemOn(t *testing.T) {
	extra := t.TempDir()
	writeTool(t, extra, "fakebrew", "#!/bin/sh\necho \"brew says hi; PATH=$PATH\"\n", 0o755)
	old := extraPath
	extraPath = []string{extra}
	defer func() { extraPath = old }()
	t.Setenv("PATH", "/usr/bin:/bin") // what a Finder-launched program has, more or less

	res, err := ExecRunner{}.Run(context.Background(), "fakebrew")
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("a tool in an extra folder must be found: %+v, %v", res, err)
	}
	if !strings.Contains(res.Stdout, "brew says hi") || !strings.Contains(res.Stdout, extra) {
		t.Errorf("the tool must see the extended PATH too: %q", res.Stdout)
	}
}

func TestExecRunner_ToolsOnTheRealPathStillWin(t *testing.T) {
	first := t.TempDir()
	writeTool(t, first, "who", "#!/bin/sh\necho first\n", 0o755)
	extra := t.TempDir()
	writeTool(t, extra, "who", "#!/bin/sh\necho extra\n", 0o755)
	old := extraPath
	extraPath = []string{extra}
	defer func() { extraPath = old }()
	t.Setenv("PATH", first+":/usr/bin:/bin")

	res, err := ExecRunner{}.Run(context.Background(), "who")
	if err != nil || strings.TrimSpace(res.Stdout) != "first" {
		t.Errorf("a folder already on PATH comes before the extras: %q, %v", res.Stdout, err)
	}
}

func TestExecRunner_ExtraEnvironmentStillOverrides(t *testing.T) {
	res, err := ExecRunner{Env: []string{"PATH=/usr/bin:/bin"}}.Run(context.Background(), "sh", "-c", "echo $PATH")
	if err != nil || strings.TrimSpace(res.Stdout) != "/usr/bin:/bin" {
		t.Errorf("a PATH given on purpose is not extended behind the caller's back: %q, %v", res.Stdout, err)
	}

	extra := t.TempDir()
	writeTool(t, extra, "onlyextra", "#!/bin/sh\necho found\n", 0o755)
	old := extraPath
	extraPath = []string{extra}
	defer func() { extraPath = old }()
	if _, err := (ExecRunner{Env: []string{"PATH=/usr/bin:/bin"}}).Run(context.Background(), "onlyextra"); err == nil {
		t.Error("a PATH given on purpose is also the one names are looked up in: the extra folders must not be searched")
	}
}

func TestIsNotFound(t *testing.T) {
	_, missing := ExecRunner{}.Run(context.Background(), "cmm-no-such-binary-xyz")
	if !IsNotFound(missing) {
		t.Errorf("a program that does not exist is not found: %v", missing)
	}
	wrapped := fmt.Errorf("while asking: %w", &exec.Error{Name: "docker", Err: exec.ErrNotFound})
	for name, err := range map[string]error{"wrapped": wrapped, "plain": exec.ErrNotFound} {
		if !IsNotFound(err) {
			t.Errorf("%s: should be recognised", name)
		}
	}
	for name, err := range map[string]error{"nil": nil, "other": errors.New("boom"), "a timeout": context.DeadlineExceeded} {
		if IsNotFound(err) {
			t.Errorf("%s must not count as a missing program", name)
		}
	}
}
