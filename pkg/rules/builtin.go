package rules

import (
	"time"

	"github.com/david-saint/cmm/pkg/guard"
)

const mb = 1 << 20

// Process guards, shared by several rules. The [x] in a pattern keeps pgrep -f from matching a shell whose
// command line merely contains the pattern text.
var (
	procGo      = guard.ProcSpec{Exact: "go"}
	procNPM     = guard.ProcSpec{Pattern: `[n]pm (install|ci|add|update|i|rebuild)( |$)`}
	procPod     = guard.ProcSpec{Pattern: `[p]od (install|update|repo)`}
	procBun     = guard.ProcSpec{Pattern: `[b]un (install|add|i|update)( |$)`}
	procUV      = guard.ProcSpec{Pattern: `(^|/)[u]vx?( |$)`}
	procUVCache = guard.ProcSpec{Pattern: `[.]cache/uv/`}
	procJest    = guard.ProcSpec{Pattern: `[j]est`}
	procXcode   = guard.ProcSpec{Exact: "Xcode"}
	procXcB     = guard.ProcSpec{Exact: "xcodebuild"}
	procSwiftF  = guard.ProcSpec{Exact: "swift-frontend"}
	procSwiftB  = guard.ProcSpec{Exact: "swift-build"}

	procMaestro       = guard.ProcSpec{Pattern: `[m]aestro`}
	procCursorApp     = guard.ProcSpec{Pattern: `/Applications/Cursor.app/Contents`}
	procCursorUpdater = guard.ProcSpec{Pattern: `[c]om.todesktop.230313mzl4w4u92.ShipIt`}
)

// Builtin returns the built-in rules in the order the dev-cleanup script used.
func Builtin() []Rule { return BuiltinWithMin(50*mb, 100*mb) }

// BuiltinWithMin is Builtin with its two size thresholds replaced, so tests can use tiny files.
// cacheMin applies to the cache rules; xcodeMin to the Xcode module and compilation caches.
func BuiltinWithMin(cacheMin, xcodeMin int64) []Rule {
	return []Rule{
		&PathRule{
			RuleID: "xcode-module-cache",
			Label:  "Xcode module/compilation cache (rebuilds on the next build)",
			Targets: []string{
				"~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex",
				"~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex",
			},
			MinBytes:   xcodeMin,
			Block:      []guard.ProcSpec{procXcode, procXcB, procSwiftF, procSwiftB},
			BlockedMsg: "Xcode is running (quit it and run again to clear this)",
		},
		&PathRule{
			RuleID:     "go-build",
			Label:      "Go build cache",
			Targets:    []string{"~/Library/Caches/go-build"},
			MinBytes:   cacheMin,
			Block:      []guard.ProcSpec{procGo},
			BlockedMsg: "a go command is running",
		},
		&PathRule{
			RuleID:     "npm-cache",
			Label:      "npm download cache",
			Targets:    []string{"~/.npm/_cacache"},
			MinBytes:   cacheMin,
			Block:      []guard.ProcSpec{procNPM},
			BlockedMsg: "an npm install is running",
		},
		&PathRule{
			RuleID:     "cocoapods",
			Label:      "CocoaPods cache",
			Targets:    []string{"~/Library/Caches/CocoaPods"},
			MinBytes:   cacheMin,
			Block:      []guard.ProcSpec{procPod},
			BlockedMsg: "pod is running",
		},
		&PathRule{
			RuleID:     "bun-cache",
			Label:      "bun cache",
			Targets:    []string{"~/.bun/install/cache"},
			MinBytes:   cacheMin,
			Block:      []guard.ProcSpec{procBun},
			BlockedMsg: "bun install is running",
		},
		&PathRule{
			RuleID:     "uv-cache",
			Label:      "uv cache (Python packages; downloads again on demand)",
			Targets:    []string{"~/.cache/uv"},
			MinBytes:   cacheMin,
			Block:      []guard.ProcSpec{procUV, procUVCache},
			BlockedMsg: "uv is running",
			CheckInUse: true,
		},
		&PathRule{
			RuleID:     "jest-temp",
			Label:      "Jest temp cache",
			Targets:    []string{"{tmp}/jest_dx"},
			MinBytes:   cacheMin,
			Block:      []guard.ProcSpec{procJest},
			BlockedMsg: "jest is running",
		},
	}
}

const (
	// idleFor is how long a project or lane must be untouched before its build output counts as abandoned.
	idleFor = 5 * 24 * time.Hour
	// goneAfter is the shorter wait for a build folder whose workspace no longer exists.
	goneAfter = 3 * 24 * time.Hour
)

// staleDerivedData removes the build folders Xcode keeps in DerivedData for projects nobody has used for
// five days (or whose workspace is gone and that were not used for three), unless something has them open.
func staleDerivedData() *BuildFoldersRule {
	return &BuildFoldersRule{
		RuleID:    "deriveddata-stale",
		Label:     "Stale Xcode build output (DerivedData)",
		Root:      "~/Library/Developer/Xcode/DerivedData",
		IdleFor:   idleFor,
		GoneAfter: goneAfter,
	}
}

// laneLocalBuildFolders is the same for the build folders made with xcodebuild -derivedDataPath next to the
// project checkouts in ~/lane-builds. They are recognised by their contents, never by name, and a folder that
// is a project (package.json, .git) is never one of them.
func laneLocalBuildFolders() *BuildFoldersRule {
	return &BuildFoldersRule{
		RuleID:    "lane-local-build",
		Label:     "Stale lane-local Xcode build folders",
		Root:      "~/lane-builds",
		Layout:    true,
		IdleFor:   idleFor,
		GoneAfter: goneAfter,
	}
}

// maestroTemp removes the per-run output folders Maestro's XCTest runner leaves in the temp dir (hundreds of
// them pile up), once they are more than an hour old and neither Maestro nor xcodebuild is running.
func maestroTemp() *ChildrenRule {
	return &ChildrenRule{
		RuleID:     "maestro-temp",
		Label:      "Maestro test output (older than 1 hour)",
		Root:       "{tmp}",
		Pattern:    "maestro_xctestrunner_xcodebuild_output*",
		OlderThan:  time.Hour,
		Block:      []guard.ProcSpec{procMaestro, procXcB},
		BlockedMsg: "Maestro or xcodebuild is running",
	}
}

// cursorUpdate removes the staged copy of an auto-update that Cursor's updater (ShipIt) gave up on, plus its
// state file, when neither Cursor nor the updater is running.
func cursorUpdate() *ChildrenRule {
	return &ChildrenRule{
		RuleID:     "cursor-update",
		Label:      "Cursor's failed update (staged copy)",
		Root:       "~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt",
		Pattern:    "update.*",
		Also:       []string{"ShipItState.plist"},
		Block:      []guard.ProcSpec{procCursorApp, procCursorUpdater},
		BlockedMsg: "Cursor or its updater is running",
	}
}

// claudeVersions removes old copies of the claude command line tool (it updates itself and keeps every
// version it ever downloaded), keeping the newest, the one linked in ~/.local/bin and any in use.
func claudeVersions() *VersionsRule {
	return &VersionsRule{
		RuleID:  "claude-versions",
		Label:   "Old claude CLI versions",
		Dir:     "~/.local/share/claude/versions",
		LinkDir: "~/.local/bin",
	}
}

// cursorAgentVersions is the same for the cursor-agent command line tool.
func cursorAgentVersions() *VersionsRule {
	return &VersionsRule{
		RuleID:  "cursor-agent-versions",
		Label:   "Old cursor-agent versions",
		Dir:     "~/.local/share/cursor-agent/versions",
		LinkDir: "~/.local/bin",
	}
}
