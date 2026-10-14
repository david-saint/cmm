package policy

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

const (
	home = "/Users/test"
	tmp  = "/var/folders/ab/cdef/T"
)

func newPolicy() *Policy { return New(&sys.Env{Home: home, TmpDir: tmp}) }

func TestValidateTarget_Accepts(t *testing.T) {
	p := newPolicy()
	for _, path := range []string{
		home + "/Library/Caches/go-build",
		home + "/.npm/_cacache",
		home + "/.cache/uv",
		home + "/.bun/install/cache",
		home + "/lane-builds/mlp-ios-dd",
		home + "/lane-builds/some-lane/node_modules",
		home + "/Library/Developer/Xcode/DerivedData/Conduxe-abcdefghijklmnopqrstuvwxyzab",
		home + "/Library/Developer/CoreSimulator/Devices/1C7EE994-6898-4D40-883D-0EF75816C39A",
		home + "/.local/share/claude/versions/2.1.292",
		tmp + "/jest_dx",
		tmp + "/maestro_xctestrunner_xcodebuild_output123",
	} {
		if err := p.ValidateTarget(path); err != nil {
			t.Errorf("ValidateTarget(%q) should be accepted, got %v", path, err)
		}
	}
}

func TestValidateTarget_RefusesMalformedPaths(t *testing.T) {
	p := newPolicy()
	for name, path := range map[string]string{
		"empty":                "",
		"relative":             "relative/path",
		"dot-relative":         "./x",
		"parent reference":     home + "/../x",
		"parent inside":        home + "/Library/Caches/../Caches/go-build",
		"double slash":         home + "/Library//Caches/x",
		"trailing slash":       home + "/.npm/_cacache/",
		"dot element":          home + "/.npm/./_cacache",
		"NUL byte":             home + "/.npm/_cacache\x00/etc",
		"root":                 "/",
		"only slashes":         "//",
		"tilde not expanded":   "~/Library/Caches/go-build",
		"environment variable": "$HOME/Library/Caches/go-build",
	} {
		if err := p.ValidateTarget(path); !errors.Is(err, ErrRefused) {
			t.Errorf("%s: ValidateTarget(%q) should be refused, got %v", name, path, err)
		}
	}
}

func TestValidateTarget_RefusesBroadDirectories(t *testing.T) {
	p := newPolicy()
	for _, path := range []string{
		"/Users",
		home,
		home + "/Library",
		home + "/.cache", // one level below home is never a target
		home + "/Documents",
		home + "/lane-builds",
		home + "/Library/Caches",
		home + "/Library/Application Support",
		home + "/Library/Developer",
		home + "/Library/Developer/Xcode",
		home + "/Library/Developer/Xcode/DerivedData",
		home + "/Library/Developer/CoreSimulator",
		home + "/Library/Developer/CoreSimulator/Devices",
		home + "/Library/Logs",
		home + "/.local/share",
		home + "/.local/bin",
		home + "/.local/state",
		home + "/.local/share/claude",
		home + "/.local/share/claude/versions",
		home + "/.local/share/cursor-agent",
		home + "/.local/share/cursor-agent/versions",
	} {
		if err := p.ValidateTarget(path); !errors.Is(err, ErrRefused) {
			t.Errorf("ValidateTarget(%q) is a broad directory and must be refused, got %v", path, err)
		}
	}
}

func TestValidateTarget_RefusesPrivateDataAreas(t *testing.T) {
	p := newPolicy()
	for _, path := range []string{
		home + "/Documents/project/x",
		home + "/Desktop/a/b",
		home + "/Downloads/big.iso",
		home + "/Pictures/Photos Library.photoslibrary/database",
		home + "/Movies/clip.mov",
		home + "/Music/Music/Media",
		home + "/Public/shared",
		home + "/.ssh/id_ed25519",
		home + "/.gnupg/private-keys-v1.d",
		home + "/.Trash/old-thing",
		home + "/Library/Mail/V10",
		home + "/Library/Messages/chat.db",
		home + "/Library/Mobile Documents/com~apple~CloudDocs/x",
		home + "/Library/CloudStorage/GoogleDrive-me/x",
		home + "/Library/Keychains/login.keychain-db",
		home + "/Library/Containers/com.apple.mail/Data",
		home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/x",
	} {
		if err := p.ValidateTarget(path); !errors.Is(err, ErrRefused) {
			t.Errorf("ValidateTarget(%q) is private data and must be refused, got %v", path, err)
		}
	}
}

func TestValidateTarget_RefusesPathsOutsideTheAllowedRoots(t *testing.T) {
	p := newPolicy()
	for name, path := range map[string]string{
		"applications":        "/Applications/Xcode.app",
		"system":              "/System/Library/AssetsV2/x",
		"library":             "/Library/Developer/CoreSimulator",
		"homebrew":            "/opt/homebrew/Cellar/boost",
		"external volume":     "/Volumes/SAINT SSD/Development/x",
		"private form of tmp": "/private" + tmp + "/jest_dx", // roots and targets must be the same form
		"tmp":                 "/tmp/x",
		"another user":        "/Users/other/Library/Caches/x",
		"prefix lookalike":    "/Users/testing/x/y",
		"tmp parent":          "/var/folders/ab/cdef/x",
	} {
		if err := p.ValidateTarget(path); !errors.Is(err, ErrRefused) {
			t.Errorf("%s: ValidateTarget(%q) should be refused, got %v", name, path, err)
		}
	}
}

func TestValidateTarget_RefusesTheTempDirItself(t *testing.T) {
	p := newPolicy()
	for _, path := range []string{tmp, tmp + "/", "/var/folders/ab/cdef", "/var/folders"} {
		if err := p.ValidateTarget(path); !errors.Is(err, ErrRefused) {
			t.Errorf("ValidateTarget(%q) should be refused, got %v", path, err)
		}
	}
}

func TestValidateTarget_ErrorsNameThePathAndReason(t *testing.T) {
	err := newPolicy().ValidateTarget(home + "/Documents/x/y")
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("want *Error, got %T", err)
	}
	if e.Path != home+"/Documents/x/y" || e.Reason == "" {
		t.Errorf("error should carry the path and a reason: %+v", e)
	}
}

func TestNew_EmptyRootsRefuseEverything(t *testing.T) {
	p := New(&sys.Env{})
	for _, path := range []string{"/Users/test/.npm/_cacache", "/var/folders/ab/cdef/T/jest_dx", "/"} {
		if err := p.ValidateTarget(path); !errors.Is(err, ErrRefused) {
			t.Errorf("a policy without roots must refuse %q, got %v", path, err)
		}
	}
}

func TestChildOf(t *testing.T) {
	cases := []struct {
		path, parent string
		want         bool
	}{
		{"/a/b/c", "/a/b", true},
		{"/a/b/c/", "/a/b/", true}, // inputs are cleaned first
		{"/a/b/c/d", "/a/b", false},
		{"/a/b", "/a/b", false},
		{"/a/bc", "/a/b", false},
		{"/a", "/a/b", false},
		{"/a/b/c", "/", false},
		{"/a", "/", true},
	}
	for _, c := range cases {
		if got := ChildOf(c.path, c.parent); got != c.want {
			t.Errorf("ChildOf(%q, %q) = %v, want %v", c.path, c.parent, got, c.want)
		}
	}
}

func TestUnder(t *testing.T) {
	cases := []struct {
		path, root string
		want       bool
	}{
		{"/a/b/c", "/a", true},
		{"/a/b", "/a/b", false},
		{"/ab/c", "/a", false}, // string prefix is not a path prefix
		{"/a", "/a/b", false},
		{"/anything", "/", true},
	}
	for _, c := range cases {
		if got := Under(c.path, c.root); got != c.want {
			t.Errorf("Under(%q, %q) = %v, want %v", c.path, c.root, got, c.want)
		}
	}
}

func TestCheckNotSymlink(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	dirLink := filepath.Join(dir, "dirlink")
	if err := os.Symlink(dir, dirLink); err != nil {
		t.Fatal(err)
	}

	if err := CheckNotSymlink(file); err != nil {
		t.Errorf("a regular file is fine: %v", err)
	}
	if err := CheckNotSymlink(dir); err != nil {
		t.Errorf("a directory is fine: %v", err)
	}
	if err := CheckNotSymlink(filepath.Join(dir, "missing")); err != nil {
		t.Errorf("a missing path has nothing to refuse: %v", err)
	}
	for _, l := range []string{link, dirLink} {
		if err := CheckNotSymlink(l); !errors.Is(err, ErrRefused) {
			t.Errorf("CheckNotSymlink(%q) should be refused, got %v", l, err)
		}
	}
}

// ---- CheckNoSymlinks: a link anywhere below the root would make a delete follow it ----

func mkdirs(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func link(t *testing.T, target, name string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, name); err != nil {
		t.Fatal(err)
	}
}

func TestCheckNoSymlinks_PlainDirectoriesPass(t *testing.T) {
	sb := systest.NewSandbox(t)
	mkdirs(t, sb.Home("lane-builds", "a", "node_modules"), sb.Tmp("jest_dx"))
	p := New(sb.Env)
	for _, path := range []string{sb.Home("lane-builds", "a", "node_modules"), sb.Tmp("jest_dx")} {
		if err := p.CheckNoSymlinks(path); err != nil {
			t.Errorf("CheckNoSymlinks(%q) = %v, want nil", path, err)
		}
	}
}

func TestCheckNoSymlinks_ASymlinkedLaneIsRefused(t *testing.T) {
	// ~/lane-builds/x is a link to a real project somewhere else (the SSD, say)
	sb := systest.NewSandbox(t)
	ssd := filepath.Join(sb.Root, "ssd", "x")
	mkdirs(t, filepath.Join(ssd, "node_modules"))
	link(t, ssd, sb.Home("lane-builds", "x"))

	err := New(sb.Env).CheckNoSymlinks(sb.Home("lane-builds", "x", "node_modules"))
	if !errors.Is(err, ErrRefused) || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("a target below a symlinked lane must be refused, got %v", err)
	}
}

func TestCheckNoSymlinks_AMiddleFolderThatIsALinkIsRefused(t *testing.T) {
	sb := systest.NewSandbox(t)
	realIOS := filepath.Join(sb.Root, "elsewhere", "ios")
	mkdirs(t, filepath.Join(realIOS, "Pods"), sb.Home("lane-builds", "a"))
	link(t, realIOS, sb.Home("lane-builds", "a", "ios"))

	if err := New(sb.Env).CheckNoSymlinks(sb.Home("lane-builds", "a", "ios", "Pods")); !errors.Is(err, ErrRefused) {
		t.Fatalf("a symlinked ios folder must be refused, got %v", err)
	}
}

func TestCheckNoSymlinks_TheLastElementCounts(t *testing.T) {
	sb := systest.NewSandbox(t)
	mkdirs(t, filepath.Join(sb.Root, "elsewhere", "cache"))
	link(t, filepath.Join(sb.Root, "elsewhere", "cache"), sb.Home(".npm", "_cacache"))

	if err := New(sb.Env).CheckNoSymlinks(sb.Home(".npm", "_cacache")); !errors.Is(err, ErrRefused) {
		t.Fatalf("a symlink as the target itself must be refused, got %v", err)
	}
}

func TestCheckNoSymlinks_MissingPathsAreFine(t *testing.T) {
	sb := systest.NewSandbox(t)
	p := New(sb.Env)
	if err := p.CheckNoSymlinks(sb.Home("no", "such", "thing")); err != nil {
		t.Errorf("a path that does not exist has nothing to follow: %v", err)
	}
	mkdirs(t, sb.Home("lane-builds"))
	if err := p.CheckNoSymlinks(sb.Home("lane-builds", "ghost", "node_modules")); err != nil {
		t.Errorf("a missing parent is fine: %v", err)
	}
}

// /var is a symlink to /private/var and every per-user temp path goes through it: only components BELOW the
// root are checked, otherwise every temp-dir target would be refused.
func TestCheckNoSymlinks_FoldersAboveTheRootMayBeLinks(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	mkdirs(t, filepath.Join(real, "home", ".npm", "_cacache"))
	linked := filepath.Join(base, "linked")
	link(t, real, linked)

	p := New(&sys.Env{Home: filepath.Join(linked, "home"), TmpDir: ""})
	if err := p.CheckNoSymlinks(filepath.Join(linked, "home", ".npm", "_cacache")); err != nil {
		t.Errorf("a link above the home directory must not matter: %v", err)
	}
}

func TestCheckNoSymlinks_TempDirTargetsAreCheckedToo(t *testing.T) {
	sb := systest.NewSandbox(t)
	mkdirs(t, filepath.Join(sb.Root, "elsewhere", "jest_dx"))
	link(t, filepath.Join(sb.Root, "elsewhere", "jest_dx"), sb.Tmp("jest_dx"))
	if err := New(sb.Env).CheckNoSymlinks(sb.Tmp("jest_dx")); !errors.Is(err, ErrRefused) {
		t.Fatalf("a symlink under the temp dir must be refused, got %v", err)
	}
}

func TestCheckNoSymlinks_RefusesWhatItCannotPlaceUnderARoot(t *testing.T) {
	sb := systest.NewSandbox(t)
	p := New(sb.Env)
	for name, path := range map[string]string{
		"outside":  "/Applications/Xcode.app",
		"the root": sb.Env.Home,
		"relative": "lane-builds/x",
		"unclean":  sb.Env.Home + "/a/../b",
	} {
		if err := p.CheckNoSymlinks(path); !errors.Is(err, ErrRefused) {
			t.Errorf("%s: %q should be refused, got %v", name, path, err)
		}
	}
}
