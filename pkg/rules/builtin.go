package rules

import "github.com/david-saint/cmm/pkg/guard"

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
