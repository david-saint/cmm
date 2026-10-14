package rules

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/sizer"
)

// volumesDir is where external disks are mounted. Tests point it at a sandbox.
var volumesDir = "/Volumes"

// projectFolderRE is how Xcode names a folder in DerivedData: the project name, a dash and 28 lowercase letters.
var projectFolderRE = regexp.MustCompile(`^[A-Za-z0-9_.+-]+-[a-z]{28}$`)

const (
	// buildFolderNoun starts every message about one of these folders.
	buildFolderNoun = "Xcode build folder"
	// buildFolderDepth is how deep recent activity is looked for: Build/Products/<file> and Logs/Build/<file>
	// are where a build leaves its marks, so anything deeper than that is not needed to tell it was used.
	buildFolderDepth = 3
)

// BuildFoldersRule removes the build output Xcode keeps per project (DerivedData) once the project is
// abandoned. A folder is stale when nothing in it has been touched for IdleFor, or when the workspace it was
// built for no longer exists and nothing in it has been touched for GoneAfter. Folders whose workspace sits on
// a disk that is not plugged in, that name no usable workspace, that something has open or whose last use
// cannot be established are left alone and reported.
//
// Only direct children of Root are ever claimed, and only those that pass the test for the rule's flavour
// (see Layout). A symbolic link is never a build folder.
type BuildFoldersRule struct {
	RuleID string
	Label  string
	Root   string // "~/Library/Developer/Xcode/DerivedData" or "~/lane-builds"
	// Layout chooses how a child of Root is recognised. False: by its name, which must be one of Xcode's own
	// (<Name>-<28 lowercase letters>) and the folder must hold an info.plist, as in DerivedData. True: by its
	// contents, whatever it is called, for folders made with xcodebuild -derivedDataPath next to project
	// checkouts: an info.plist naming a workspace, a Build folder, Index.noindex or Logs, and neither a
	// package.json nor a .git (those make it a project, not build output).
	Layout    bool
	IdleFor   time.Duration // untouched this long: stale
	GoneAfter time.Duration // workspace gone and untouched this long: stale (never longer than IdleFor)
	Tier      Tier          // empty means TierSafe
}

// ID implements Rule.
func (r *BuildFoldersRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *BuildFoldersRule) Group() string { return r.Label }

func (r *BuildFoldersRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

func (r *BuildFoldersRule) goneAfter() time.Duration {
	if r.GoneAfter <= 0 || r.GoneAfter > r.IdleFor {
		return r.IdleFor
	}
	return r.GoneAfter
}

// idleWords says the idle limit the way a person would ("not used for 5+ days").
func (r *BuildFoldersRule) idleWords() string {
	return fmt.Sprintf("not used for %d+ days", int(r.IdleFor/(24*time.Hour)))
}

func hasInfoPlist(dir string) bool { return regularFile(filepath.Join(dir, "info.plist")) }

// projectName is the folder name without Xcode's trailing "-<hash>".
func projectName(folder string) string {
	if projectFolderRE.MatchString(folder) {
		return folder[:len(folder)-len("-")-28]
	}
	return folder
}

// tilde writes a path under the home folder as ~/..., anything else in full.
func tilde(d Deps, p string) string {
	if d.Env.Home != "" && policy.Under(p, d.Env.Home) {
		return "~" + strings.TrimPrefix(p, d.Env.Home)
	}
	return p
}

// readWorkspace reads the workspace path Xcode recorded in the folder's info.plist (whatever it says).
func readWorkspace(ctx context.Context, d Deps, dir string) (string, error) {
	res, err := d.Env.Runner.Run(ctx, "plutil", "-extract", "WorkspacePath", "raw", filepath.Join(dir, "info.plist"))
	if err != nil {
		return "", err
	}
	if res.ExitCode != 0 {
		return "", fmt.Errorf("plutil exited with status %d", res.ExitCode)
	}
	return strings.TrimRight(res.Stdout, "\r\n"), nil
}

// workspace is readWorkspace, but an empty or relative answer is not usable and reported as an error.
func workspace(ctx context.Context, d Deps, dir string) (string, error) {
	ws, err := readWorkspace(ctx, d, dir)
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(ws) {
		return "", fmt.Errorf("%q is not an absolute path", ws)
	}
	return ws, nil
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// absent reports whether nothing at all (not even a dangling link) is at p; a path that cannot be looked at
// counts as present.
func absent(p string) bool {
	_, err := os.Lstat(p)
	return errors.Is(err, fs.ErrNotExist)
}

// looksLikeDerivedData is the content test for the Layout flavour: the shape of an Xcode DerivedData folder
// and none of the marks of a project. The cheap file checks run first so plutil only runs for real candidates.
func looksLikeDerivedData(ctx context.Context, d Deps, dir string) bool {
	if st, err := os.Lstat(dir); err != nil || !st.IsDir() {
		return false // a link, a file or nothing
	}
	if !hasInfoPlist(dir) || !isDir(filepath.Join(dir, "Build")) {
		return false
	}
	if !isDir(filepath.Join(dir, "Index.noindex")) && !isDir(filepath.Join(dir, "Logs")) {
		return false
	}
	for _, mark := range []string{"package.json", ".git"} {
		if !absent(filepath.Join(dir, mark)) {
			return false
		}
	}
	_, err := readWorkspace(ctx, d, dir)
	return err == nil
}

// isBuildFolder is the content test for a child of Root, according to the rule's flavour.
func (r *BuildFoldersRule) isBuildFolder(ctx context.Context, d Deps, dir string) bool {
	if r.Layout {
		return looksLikeDerivedData(ctx, d, dir)
	}
	return hasInfoPlist(dir)
}

// unmountedVolume returns the volume a workspace lives on when that disk is not plugged in, or "".
func unmountedVolume(ws string) string {
	prefix := volumesDir + "/"
	if !strings.HasPrefix(ws, prefix) {
		return ""
	}
	vol := prefix + strings.SplitN(ws[len(prefix):], "/", 2)[0]
	if st, err := os.Stat(vol); err != nil || !st.IsDir() {
		return vol
	}
	return ""
}

type staleFolder struct {
	workspace string
	why       string
}

// check judges one build folder, both when planning and again right before deleting. It returns
//   - (nil, "") when the folder stays and there is nothing to say about it,
//   - (nil, reason) when it must be skipped and the reason reported,
//   - (stale, "") when it is stale and nothing has it open.
func (r *BuildFoldersRule) check(ctx context.Context, d Deps, dir string) (*staleFolder, string) {
	name := filepath.Base(dir)
	skip := func(format string, args ...any) (*staleFolder, string) {
		return nil, fmt.Sprintf("%s %s: %s", buildFolderNoun, name, fmt.Sprintf(format, args...))
	}
	used := func(within time.Duration) (bool, error) {
		return d.Guard.RecentlyModified(dir, guard.Recent{Within: within, MaxDepth: buildFolderDepth})
	}

	recent, err := used(r.goneAfter())
	if err != nil {
		return skip("could not check how recently it was used (%v)", err)
	}
	if recent {
		return nil, ""
	}

	ws, err := workspace(ctx, d, dir)
	if err != nil {
		return skip("no usable workspace path recorded (%v)", err)
	}

	stale := &staleFolder{workspace: ws}
	recent, err = used(r.IdleFor)
	if err != nil {
		return skip("could not check how recently it was used (%v)", err)
	}
	if !recent {
		stale.why = r.idleWords()
	} else {
		_, err := os.Stat(ws)
		switch {
		case err == nil:
			return nil, "" // the project still exists and was used within the idle limit
		case errors.Is(err, fs.ErrNotExist):
			stale.why = "workspace no longer exists"
		default:
			return skip("could not check whether its workspace exists (%v)", err)
		}
	}

	if vol := unmountedVolume(ws); vol != "" {
		return skip("its volume (%s) is not mounted", vol)
	}
	inUse, err := d.Guard.InUse(ctx, dir)
	if err != nil {
		return skip("could not check whether it is in use (%v)", err)
	}
	if inUse {
		return skip("in use")
	}
	return stale, ""
}

// Plan implements Rule.
func (r *BuildFoldersRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	root, ok := expandRoot(d, r.Root)
	if !ok {
		return nil, nil, nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, nil
		}
		return nil, []Skip{{Reason: fmt.Sprintf("%s: cannot read %s (%v)", r.Label, root, err)}}, nil
	}
	if err := d.Policy.CheckNoSymlinks(root); err != nil {
		return nil, []Skip{{Reason: fmt.Sprintf("%s: %v", r.Label, err)}}, nil
	}

	var items []Candidate
	var skips []Skip
	for _, e := range entries {
		name := e.Name()
		if !r.Layout && !projectFolderRE.MatchString(name) {
			continue
		}
		if e.Type()&fs.ModeSymlink != 0 {
			// in a folder of project checkouts a link is none of this rule's business; among Xcode's own
			// project folders it is worth a word
			if !r.Layout {
				skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: is a symbolic link, left alone", buildFolderNoun, name)})
			}
			continue
		}
		p := filepath.Join(root, name)
		if !e.IsDir() || !r.isBuildFolder(ctx, d, p) {
			continue
		}
		if err := d.Policy.CheckNoSymlinks(p); err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: %v", buildFolderNoun, name, err)})
			continue
		}
		found, reason := r.check(ctx, d, p)
		if reason != "" {
			skips = append(skips, Skip{Reason: reason})
			continue
		}
		if found == nil {
			continue
		}
		res, err := sizer.Measure(p)
		if err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s %s: could not measure (%v)", buildFolderNoun, name, err)})
			continue
		}
		c := Candidate{
			Rule: r.RuleID, Group: r.Label, Path: p, Bytes: res.Bytes, Tier: r.tier(), Action: ActionDelete,
			Note: fmt.Sprintf("%s: %s (%s)", projectName(name), tilde(d, found.workspace), found.why),
		}
		if res.Unreadable > 0 {
			c.Note += fmt.Sprintf("; %d entries could not be read, so the size is a lower bound", res.Unreadable)
		}
		items = append(items, c)
	}
	return items, skips, nil
}

// allowsTimeout bounds the one command the Layout flavour's content test may run.
const allowsTimeout = 30 * time.Second

// Allows implements Rule: only direct children of Root that pass the rule's test (by name for Xcode's own
// project folders, by contents for the Layout flavour, which looks at the disk each time it is asked).
func (r *BuildFoldersRule) Allows(d Deps, p string) bool {
	root, ok := expandRoot(d, r.Root)
	if !ok || p == "" || filepath.Clean(p) != p || !policy.ChildOf(p, root) {
		return false
	}
	if !r.Layout {
		return projectFolderRE.MatchString(filepath.Base(p))
	}
	ctx, cancel := context.WithTimeout(context.Background(), allowsTimeout)
	defer cancel()
	return looksLikeDerivedData(ctx, d, p)
}

// Recheck implements Rule: everything is judged again, because a build can start between planning and applying.
func (r *BuildFoldersRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	name := filepath.Base(c.Path)
	if !r.isBuildFolder(ctx, d, c.Path) {
		return fmt.Errorf("%s %s: no longer looks like an Xcode build folder", buildFolderNoun, name)
	}
	found, reason := r.check(ctx, d, c.Path)
	switch {
	case reason != "":
		return errors.New(reason)
	case found == nil:
		return fmt.Errorf("%s %s: used again since the plan was made", buildFolderNoun, name)
	}
	return nil
}
