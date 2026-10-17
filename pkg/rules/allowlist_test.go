package rules_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

const (
	day      = 24 * time.Hour
	hash28   = "abcdefghijklmnopqrstuvwxyzab" // 28 letters, like a real DerivedData hash
	goodUDID = "1C7EE994-6898-4D40-883D-0EF75816C39A"
)

func depsOf(sb *systest.Sandbox) rules.Deps {
	return rules.Deps{Env: sb.Env, Guard: guard.New(sb.Env), Policy: policy.New(sb.Env)}
}

func mustMkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustSymlink(t *testing.T, target, link string) {
	t.Helper()
	mustMkdir(t, filepath.Dir(link))
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

// TestAllowList_PortedFromDevCleanupSelfTest runs, against the built-in rules and the real engine, every case
// of `dev-cleanup --self-test` (96 checks). The shell ran them against the real disk; here the folders that
// made the look-alikes dangerous (a lane with a package.json that also looks like DerivedData, a project one
// level down) are created in the sandbox, so a refusal is a refusal of their contents and not of their absence.
func TestAllowList_PortedFromDevCleanupSelfTest(t *testing.T) {
	sb := systest.NewSandbox(t)
	e := engineFor(sb, rules.Builtin())
	h := sb.Home()
	dd := h + "/Library/Developer/Xcode/DerivedData"
	lb := h + "/lane-builds"
	shipit := h + "/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"
	tmp := sb.Env.TmpDir
	devices := h + "/Library/Developer/CoreSimulator/Devices"

	// the look-alikes the real disk had
	lane := lb + "/ios27-scene-cloud-mobile"
	sb.WriteFile(t, lane+"/package.json", 20, 30*day)
	sb.WriteFile(t, lane+"/info.plist", 20, 30*day) // DerivedData-shaped as well: the package.json must win
	sb.WriteFile(t, lane+"/Build/Products/x", 20, 30*day)
	sb.WriteFile(t, lane+"/Logs/x", 20, 30*day)
	sb.WriteFile(t, lane+"/node_modules/x", 20, 30*day)
	sub := lb + "/bakeoff-v2-main-d09b14a6d"
	sb.WriteFile(t, sub+"/cloud-mobile/package.json", 20, 30*day)
	sb.WriteFile(t, sub+"/cloud-mobile/node_modules/x", 20, 30*day)
	sb.WriteFile(t, sub+"/cloud-mobile/android/app/build/x", 20, 30*day)
	sb.WriteFile(t, h+"/.local/share/claude/versions/2.1.292", 20, 30*day)
	sb.WriteFile(t, h+"/.local/bin/agy", 20, 30*day)
	mustSymlink(t, h+"/.local/share/claude/versions/2.1.292", h+"/.local/bin/claude")
	sb.WriteFile(t, h+"/Library/Caches/go-build/x", 20, 30*day)
	sb.WriteFile(t, dd+"/Conduxe-"+hash28+"/Build/x", 20, 30*day)

	checks := 0
	allowed := func(paths ...string) {
		t.Helper()
		for _, p := range paths {
			checks++
			if !e.Allowed(p) {
				t.Errorf("must be allowed: %q", p)
			}
		}
	}
	refused := func(paths ...string) {
		t.Helper()
		for _, p := range paths {
			checks++
			if e.Allowed(p) {
				t.Errorf("must be refused: %q", p)
			}
		}
	}

	allowed(
		h+"/Library/Caches/go-build", h+"/.npm/_cacache", h+"/Library/Caches/CocoaPods", h+"/.bun/install/cache", h+"/.cache/uv",
		dd+"/ModuleCache.noindex", dd+"/CompilationCache.noindex", dd+"/Conduxe-"+hash28, dd+"/My_App.v2-"+hash28,
		lb+"/some-lane/node_modules", lb+"/some-lane/ios/Pods", lb+"/some-lane/ios/build",
		lb+"/some-lane/android/build", lb+"/some-lane/android/.gradle", lb+"/some-lane/android/app/build", lb+"/some-lane/android/app/.cxx",
		shipit+"/update.AbC123", shipit+"/ShipItState.plist",
		h+"/.local/share/claude/versions/2.1.292", h+"/.local/share/cursor-agent/versions/2026.09.28-64d2043",
		tmp+"/jest_dx", tmp+"/maestro_xctestrunner_xcodebuild_output123",
	)

	refused(
		"", "/", h, h+"/Library", h+"/Library/Caches", h+"/Library/Caches/go-build/..", h+"/Library/Caches/go-build/../..",
		h+"/Library/Caches/go-build/x", h+"/.npm", h+"/.npm/_npx", h+"/.npm/_cacache/x",
		h+"/.cache", h+"/.cache/uv/x", h+"/.cache/codex-runtimes", h+"/.local/share/uv",
		dd, dd+"/Logs", dd+"/Conduxe-short", dd+"/Conduxe-"+hash28[:27], dd+"/Conduxe-"+hash28+"c", dd+"/Conduxe-ABCDEFGHIJKLMNOPQRSTUVWXYZAB",
		dd+"/Conduxe-"+hash28+"/Build", dd+"/ModuleCache.noindex/x", dd+"/Index.noindex",
		lb, lb+"/some-lane", lb+"/some-lane/ios", lb+"/some-lane/src", lb+"/some-lane/android", lb+"/some-lane/android/app",
		lb+"/some-lane/.env", lb+"/some-lane/package.json",
		lb+"/a/b/node_modules", lb+"/a/b/ios/Pods", lb+"/a/b/ios/build", lb+"/a/b/android/build", lb+"/a/b/android/.gradle",
		lb+"/a/b/android/app/build", lb+"/a/b/android/app/.cxx", lb+"/a/b/c/android/app/build",
		lb+"/some-lane/node_modules/x", lb+"/some-lane/ios/build/x", lb+"/some-lane/android/app/build/x",
		lb+"/ios27-scene-cloud-mobile", lb+"/bakeoff-v2-main-d09b14a6d", lb+"/bakeoff-v2-main-d09b14a6d/cloud-mobile",
		shipit, shipit+"/ShipIt_stderr.log", shipit+"/update.x/Cursor.app",
		h+"/.local/share/claude/versions", h+"/.local/share/claude/versions/2.1.294/x", h+"/.local/share/claude/versions/latest",
		h+"/.local/bin/claude", h+"/.local/bin/agy",
		"/Applications/Xcode.app", "/System/Library/AssetsV2", "/Library/Developer", "/opt/homebrew/Cellar", "/Volumes/SAINT SSD", "/Volumes/SAINT SSD/Development",
		tmp, tmp+"/jest_dx2", tmp+"/other", tmp+"/maestro_xctestrunner_xcodebuild_output1/inner",
	)

	// the content test for lane-local build folders must reject non-folders, real lanes and look-alikes
	var layout rules.Rule
	for _, r := range rules.Builtin() {
		if r.ID() == "lane-local-build" {
			layout = r
		}
	}
	if layout == nil {
		t.Fatal("the lane-local-build rule is missing")
	}
	for _, p := range []string{h, lb, lb + "/does-not-exist", h + "/Library/Developer/Xcode"} {
		checks++
		if layout.Allows(depsOf(sb), p) {
			t.Errorf("the layout test accepted %q", p)
		}
	}

	// simulator ids: only well-formed ids; the good one may be deleted, the others are refused
	for _, u := range []string{"", "../x", "x", goodUDID + "/..", "not-a-uuid"} {
		checks++
		if e.Allowed(devices + "/" + u) {
			t.Errorf("the id %q was accepted", u)
		}
	}
	allowed(devices + "/" + goodUDID)

	if checks != 96 {
		t.Errorf("this port must cover all 96 cases of dev-cleanup --self-test, it ran %d", checks)
	}
}

// Cases the shell test did not have: other people's folders, personal data, links, look-alike roots, the
// action name of a command rule and folders recognised by their contents.
func TestAllowList_BeyondTheShellSelfTest(t *testing.T) {
	t.Run("never other homes, personal data or look-alike roots", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		e := engineFor(sb, rules.Builtin())
		h := sb.Home()
		for _, p := range []string{
			"/Users/other/Library/Caches/go-build", "/Users/other/lane-builds/x/node_modules",
			h + "/Documents/lane-builds/x/node_modules", h + "/Desktop/node_modules", h + "/.ssh/known_hosts", h + "/Library/Mail/x",
			h + "/lane-builds-old/x/node_modules", h + "/Library/Caches-old/go-build", h + "/.npm-old/_cacache",
			h + "/Library/Developer/Xcode/DerivedData-old/Conduxe-" + hash28,
			"homebrew: cleanup", "homebrew", "brew cleanup",
			"docker: unused images", "docker: stopped containers", "docker: build cache", "docker: volumes", "docker: volume prune", "docker",
			// cmm's own records: the log, the stamp, the history and the free-space samples are never cleanup targets
			h + "/.local/state/cmm", h + "/.local/state/cmm/cleanup.log", h + "/.local/state/cmm/last-run",
			h + "/.local/state/cmm/history.jsonl", h + "/.local/state/cmm/free.jsonl", h + "/.local/state",
		} {
			if e.Allowed(p) {
				t.Errorf("must be refused: %q", p)
			}
		}
	})

	t.Run("a lane-local build folder is allowed by its contents, and not once it grows a package.json", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		e := engineFor(sb, rules.Builtin())
		dir := sb.Home("lane-builds", "mlp-ios-dd")
		for _, f := range []string{"info.plist", "Build/Products/x", "Logs/x"} {
			sb.WriteFile(t, filepath.Join(dir, f), 20, 30*day)
		}
		sb.Runner.Stub(sys.Result{Stdout: "/Users/x/App.xcworkspace\n"}, nil, "plutil", "-extract", "WorkspacePath", "raw", filepath.Join(dir, "info.plist"))
		if !e.Allowed(dir) {
			t.Error("a folder with the DerivedData layout must be allowed")
		}
		sb.WriteFile(t, filepath.Join(dir, "package.json"), 20, 0)
		if e.Allowed(dir) {
			t.Error("a folder with a package.json is a lane")
		}
	})

	t.Run("links are refused wherever they sit below the home folder", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		e := engineFor(sb, rules.Builtin())
		h := sb.Home()
		elsewhere := filepath.Join(sb.Root, "ssd")

		// a linked lane
		mustMkdir(t, elsewhere+"/lane/node_modules")
		mustSymlink(t, elsewhere+"/lane", h+"/lane-builds/linked")
		mustMkdir(t, h+"/lane-builds/plain/node_modules")
		// a linked Caches folder and a linked cache
		mustMkdir(t, elsewhere+"/Caches/go-build")
		mustSymlink(t, elsewhere+"/Caches", h+"/Library/Caches")
		mustMkdir(t, elsewhere+"/npm")
		mustSymlink(t, elsewhere+"/npm", h+"/.npm")
		mustMkdir(t, elsewhere+"/uv")
		mustSymlink(t, elsewhere+"/uv", h+"/.cache/uv")
		// a linked DerivedData project
		mustMkdir(t, elsewhere+"/dd")
		mustSymlink(t, elsewhere+"/dd", h+"/Library/Developer/Xcode/DerivedData/Conduxe-"+hash28)

		if !e.Allowed(h + "/lane-builds/plain/node_modules") {
			t.Error("setup: the same shape without a link is fine")
		}
		for _, p := range []string{
			h + "/lane-builds/linked/node_modules",
			h + "/Library/Caches/go-build",
			h + "/.npm/_cacache",
			h + "/.cache/uv",
			h + "/Library/Developer/Xcode/DerivedData/Conduxe-" + hash28,
		} {
			if e.Allowed(p) {
				t.Errorf("a link on the way: must be refused: %q", p)
			}
		}
	})
}
