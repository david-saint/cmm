package rules

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"

	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/sizer"
)

// VersionsRule removes old copies of a self-updating command line tool. Each version lives in a folder (or a
// single file) named after its version number under Dir; the rule keeps the newest one, every version that a
// link in LinkDir points at (the one on the PATH), and any version something has open.
//
// The links and the in-use state are read again right before a deletion, because an updater can relink or
// start a tool between planning and applying.
type VersionsRule struct {
	RuleID  string
	Label   string
	Dir     string // "~/.local/share/claude/versions"; its parent folder's name is the tool name
	LinkDir string // "~/.local/bin": symlinks here that point into Dir mark versions as wanted
	Tier    Tier   // empty means TierSafe
}

// ID implements Rule.
func (r *VersionsRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *VersionsRule) Group() string { return r.Label }

func (r *VersionsRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

func isVersionName(name string) bool {
	return name != "" && unicode.IsDigit(rune(name[0]))
}

type versionState struct {
	dir      string
	tool     string
	names    []string        // real (non-link) version-numbered entries, sorted by name
	symlinks []string        // version-numbered entries that are symbolic links: reported, never ranked or planned
	newest   string          // the most recently modified real entry
	linked   map[string]bool // versions a link in LinkDir points at
}

// state reads the versions folder and the links. It is called both when planning and when re-checking.
func (r *VersionsRule) state(d Deps) (*versionState, error) {
	dir, ok := expand(d, r.Dir)
	if !ok {
		return nil, fmt.Errorf("%s: invalid versions folder %q", r.Label, r.Dir)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	st := &versionState{dir: dir, tool: filepath.Base(filepath.Dir(dir)), linked: map[string]bool{}}

	var newestTime int64
	for _, e := range entries {
		if !isVersionName(e.Name()) {
			continue
		}
		if e.Type()&fs.ModeSymlink != 0 {
			// a link's own modification time is when the link was made, not when the version was installed,
			// so it must not take part in deciding which version is the newest
			st.symlinks = append(st.symlinks, e.Name())
			continue
		}
		st.names = append(st.names, e.Name())
		info, err := e.Info()
		if err != nil {
			continue
		}
		// newest by modification time; ties go to the higher name so the answer is stable
		if t := info.ModTime().UnixNano(); st.newest == "" || t > newestTime || (t == newestTime && e.Name() > st.newest) {
			st.newest, newestTime = e.Name(), t
		}
	}
	sort.Strings(st.names)
	sort.Strings(st.symlinks)

	if linkDir, ok := expand(d, r.LinkDir); ok {
		links, err := os.ReadDir(linkDir)
		if err == nil {
			for _, l := range links {
				if l.Type()&fs.ModeSymlink == 0 {
					continue
				}
				target, err := os.Readlink(filepath.Join(linkDir, l.Name()))
				if err != nil {
					continue
				}
				if name := versionFromLink(target, st.dir, st.tool); name != "" {
					st.linked[name] = true
				}
			}
		}
	}
	return st, nil
}

// versionFromLink names the version a link target belongs to, or "". An absolute target inside dir is read
// exactly; otherwise the text "/<tool>/versions/<name>" is looked for, which also catches relative links and
// errs on the side of keeping more.
func versionFromLink(target, dir, tool string) string {
	first := func(s string) string {
		if i := strings.IndexByte(s, '/'); i >= 0 {
			s = s[:i]
		}
		return s
	}
	if filepath.IsAbs(target) {
		if clean := filepath.Clean(target); policy.Under(clean, dir) {
			return first(strings.TrimPrefix(clean, dir+string(filepath.Separator)))
		}
	}
	marker := "/" + tool + "/versions/"
	if i := strings.Index(target, marker); i >= 0 {
		return first(target[i+len(marker):])
	}
	return ""
}

// Plan implements Rule.
func (r *VersionsRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	st, err := r.state(d)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, nil
		}
		return nil, []Skip{{Reason: fmt.Sprintf("%s: cannot read the versions folder (%v)", r.Label, err)}}, nil
	}
	var items []Candidate
	var skips []Skip
	for _, name := range st.symlinks {
		skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: is a symbolic link, left alone", st.tool, name)})
	}
	if len(st.names) < 2 {
		return nil, skips, nil // the only version is the newest
	}

	for _, name := range st.names {
		if name == st.newest || st.linked[name] {
			continue
		}
		p := filepath.Join(st.dir, name)
		if err := d.Policy.CheckNoSymlinks(p); err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: %v", st.tool, name, err)})
			continue
		}
		inUse, err := d.Guard.InUse(ctx, p)
		if err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: could not check whether it is in use (%v)", st.tool, name, err)})
			continue
		}
		if inUse {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: in use", st.tool, name)})
			continue
		}
		res, err := sizer.Measure(p)
		if err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: could not measure (%v)", st.tool, name, err)})
			continue
		}
		items = append(items, Candidate{Rule: r.RuleID, Group: r.Label, Path: p, Bytes: res.Bytes, Tier: r.tier(), Action: ActionDelete})
	}
	return items, skips, nil
}

// Allows implements Rule: only version-numbered direct children of Dir.
func (r *VersionsRule) Allows(d Deps, p string) bool {
	dir, ok := expand(d, r.Dir)
	if !ok || p == "" || filepath.Clean(p) != p || !policy.ChildOf(p, dir) {
		return false
	}
	return isVersionName(filepath.Base(p))
}

// Recheck implements Rule: the newest version and the links are read again, and so is the in-use state.
func (r *VersionsRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	st, err := r.state(d)
	if err != nil {
		return fmt.Errorf("%s: cannot read the versions folder (%v)", r.Label, err)
	}
	name := filepath.Base(c.Path)
	if name == st.newest {
		return fmt.Errorf("%s %s: is now the newest version", st.tool, name)
	}
	if st.linked[name] {
		return fmt.Errorf("%s %s: is now linked from %s", st.tool, name, r.LinkDir)
	}
	inUse, err := d.Guard.InUse(ctx, c.Path)
	if err != nil {
		return fmt.Errorf("%s %s: could not check whether it is in use (%v)", st.tool, name, err)
	}
	if inUse {
		return fmt.Errorf("%s %s: in use", st.tool, name)
	}
	return nil
}
