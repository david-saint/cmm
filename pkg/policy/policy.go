// Package policy is the backstop behind every cleanup rule: whatever a rule claims, a path is only a
// candidate for deletion if it lies strictly inside the user's home or per-user temp directory, is not a
// broad directory, is not inside an area that holds the user's own documents or private data, and is
// written in a clean, unambiguous form.
//
// Paths are compared as plain cleaned strings and never resolved through symlinks, so roots and targets must
// use the same form (the per-user temp dir is /var/folders/..., not /private/var/folders/...).
package policy

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/david-saint/cmm/pkg/sys"
)

// ErrRefused is wrapped by every refusal.
var ErrRefused = errors.New("policy: refused")

// Error says which path was refused and why.
type Error struct {
	Path   string
	Reason string
}

func (e *Error) Error() string { return fmt.Sprintf("policy: refused %q: %s", e.Path, e.Reason) }

// Unwrap lets errors.Is(err, ErrRefused) work.
func (e *Error) Unwrap() error { return ErrRefused }

func refuse(path, format string, args ...any) error {
	return &Error{Path: path, Reason: fmt.Sprintf(format, args...)}
}

// Policy holds the two roots a deletion target may live in.
type Policy struct {
	Home   string
	TmpDir string
}

// New builds a Policy from an Env.
func New(env *sys.Env) *Policy {
	return &Policy{Home: env.Home, TmpDir: env.TmpDir}
}

// broad lists directories (relative to the home directory) that are far too wide to delete, however
// they are reached. Anything one level below the home directory is refused separately.
var broad = map[string]bool{
	"Library/Application Support":             true,
	"Library/Caches":                          true,
	"Library/Developer":                       true,
	"Library/Developer/Xcode":                 true,
	"Library/Developer/Xcode/DerivedData":     true,
	"Library/Developer/CoreSimulator":         true,
	"Library/Developer/CoreSimulator/Devices": true,
	"Library/Logs":                            true,
	"Library/Preferences":                     true,
	"Library/LaunchAgents":                    true,
	".local/share":                            true,
	".local/bin":                              true,
	".local/state":                            true,
	".local/share/claude":                     true,
	".local/share/claude/versions":            true,
	".local/share/cursor-agent":               true,
	".local/share/cursor-agent/versions":      true,
}

// protected lists areas (relative to the home directory) where nothing may be deleted at any depth: the
// user's own documents, media, credentials and the data of apps that sync or hold personal content.
var protected = []string{
	"Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
	".ssh", ".gnupg", ".Trash",
	"Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/CloudStorage",
	"Library/Keychains", "Library/Containers", "Library/Group Containers",
}

// ValidateTarget returns nil if path may be considered as a deletion target at all. It checks the form of the
// path and where it lives; whether a rule actually claims it is decided elsewhere.
func (p *Policy) ValidateTarget(path string) error {
	switch {
	case path == "":
		return refuse(path, "empty path")
	case strings.ContainsRune(path, 0):
		return refuse(path, "contains a NUL byte")
	case !filepath.IsAbs(path):
		return refuse(path, "not an absolute path")
	case filepath.Clean(path) != path:
		return refuse(path, "not a clean path (.., //, a trailing slash or . elements)")
	}

	if p.Home != "" && Under(path, p.Home) {
		return p.validateUnderHome(path)
	}
	if p.TmpDir != "" && Under(path, p.TmpDir) {
		return nil // anything strictly below the per-user temp dir; the temp dir itself is not "under" itself
	}
	return refuse(path, "outside the allowed roots (home and the per-user temp dir)")
}

func (p *Policy) validateUnderHome(path string) error {
	rel, err := filepath.Rel(p.Home, path)
	if err != nil {
		return refuse(path, "cannot relate to the home directory")
	}
	if !strings.Contains(rel, string(filepath.Separator)) {
		return refuse(path, "directly inside the home directory")
	}
	if broad[rel] {
		return refuse(path, "a broad directory")
	}
	for _, area := range protected {
		if rel == area || strings.HasPrefix(rel, area+string(filepath.Separator)) {
			return refuse(path, "inside %s, which holds personal data", area)
		}
	}
	return nil
}

// CheckNotSymlink refuses a path whose last element is a symbolic link. A missing path is not an error:
// there is nothing to delete.
func CheckNotSymlink(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return refuse(path, "cannot stat: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return refuse(path, "is a symbolic link")
	}
	return nil
}

// ChildOf reports whether path is a direct child of parent (both are cleaned first).
func ChildOf(path, parent string) bool {
	path, parent = filepath.Clean(path), filepath.Clean(parent)
	return path != parent && filepath.Dir(path) == parent
}

// Under reports whether path lies strictly inside root (both are cleaned first). "/ab/c" is not under "/a".
func Under(path, root string) bool {
	path, root = filepath.Clean(path), filepath.Clean(root)
	if path == root {
		return false
	}
	if root == string(filepath.Separator) {
		return true
	}
	return strings.HasPrefix(path, root+string(filepath.Separator))
}
