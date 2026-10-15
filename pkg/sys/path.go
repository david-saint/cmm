package sys

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// extraPath lists folders added to the end of PATH when they are missing. A program started from Finder or
// launchd gets only the system folders, and without these the Homebrew rule would not find brew. (A variable so
// that tests can point it at a temporary folder.)
var extraPath = []string{"/opt/homebrew/bin", "/usr/local/bin"}

// systemPath is what an empty PATH is taken to mean.
const systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

// withExtraPath returns path with the extra folders appended where they are missing, in front of nothing: the
// folders already on PATH keep their order and their priority. Empty elements (which mean "the current folder")
// are dropped, and an empty path becomes the system folders.
func withExtraPath(path string) string {
	var dirs []string
	have := map[string]bool{}
	for _, d := range strings.Split(path, ":") {
		if d != "" {
			dirs = append(dirs, d)
			have[d] = true
		}
	}
	if len(dirs) == 0 {
		dirs = strings.Split(systemPath, ":")
		for _, d := range dirs {
			have[d] = true
		}
	}
	for _, d := range extraPath {
		if !have[d] {
			dirs = append(dirs, d)
			have[d] = true
		}
	}
	return strings.Join(dirs, ":")
}

// lookPath finds name in the given PATH. exec.Command looks only at the process's own PATH, which is not enough
// here, so the search is done by hand. Folders that are not absolute (including the current folder) are never
// searched, and only regular files with an execute bit count. A name with a slash is returned as it is.
func lookPath(name, path string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	for _, dir := range strings.Split(path, ":") {
		if !filepath.IsAbs(dir) {
			continue
		}
		p := filepath.Join(dir, name)
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return p, nil
		}
	}
	return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
}

// environment is the environment a command gets and the PATH its name is looked up in: the inherited
// environment with PATH extended, then the runner's own variables. A PATH given on purpose is used as it is.
func (r ExecRunner) environment() (env []string, path string) {
	path = withExtraPath(os.Getenv("PATH"))
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "PATH=") {
			env = append(env, kv)
		}
	}
	env = append(env, "PATH="+path)
	for _, kv := range r.Env {
		env = append(env, kv)
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			path = v
		}
	}
	return env, path
}

// IsNotFound reports whether err says the program does not exist on this machine, so a rule can stay silent about
// a tool that is simply not installed. (Only this package imports os/exec; see the boundary tests.)
func IsNotFound(err error) bool { return errors.Is(err, exec.ErrNotFound) }
