package engine

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// These tests read the repository's own source so the safety architecture cannot erode quietly:
//
//   - only pkg/sys starts processes, so every external tool is reached through the Runner that tests can fake;
//   - only pkg/engine deletes or moves files, so every deletion has passed the policy, the rule's Allows and
//     Recheck, the symlink checks and the human-approval gate.
//
// The Time Machine module (the one legacy module `cmm run` still offers, manual and harsh) predates the engine
// and starts processes itself; it is the one listed exception. An exception that no longer has anything to
// except fails the test, so the list can only shrink.

type boundary struct {
	what    string
	imports []string            // import paths that may not be used
	calls   map[string][]string // import path -> functions that may not be called
	allowed []string            // repo-relative path prefixes where the above is fine
}

var boundaries = []boundary{
	{
		what:    "start a process",
		imports: []string{"os/exec"},
		calls:   map[string][]string{"os": {"StartProcess"}, "syscall": {"Exec", "ForkExec"}},
		allowed: []string{"pkg/sys/"},
	},
	{
		what:  "delete or move a file",
		calls: map[string][]string{"os": {"Remove", "RemoveAll", "Rename"}, "syscall": {"Unlink", "Rmdir", "Rename"}},
		// the engine is the only place cmm deletes; everything else asks it
		allowed: []string{"pkg/engine/"},
	},
}

// exceptions are known, temporary violations: prefix + index into boundaries.
var exceptions = []struct {
	prefix   string
	boundary int
}{
	{"pkg/modules/timemachine.go", 0},
}

type finding struct {
	boundary int
	what     string
	line     int
}

// findings parses one Go file and lists the boundary violations in it, whatever name the packages are imported as.
func findings(filename string, src any) ([]finding, error) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filename, src, parser.SkipObjectResolution)
	if err != nil {
		return nil, err
	}
	var out []finding
	local := map[string]string{} // name used in this file -> import path
	for _, imp := range f.Imports {
		p := strings.Trim(imp.Path.Value, `"`)
		name := path.Base(p)
		if imp.Name != nil {
			name = imp.Name.Name
		}
		local[name] = p
		for i, b := range boundaries {
			for _, bad := range b.imports {
				if p == bad {
					out = append(out, finding{i, "imports " + p, fset.Position(imp.Pos()).Line})
				}
			}
		}
	}
	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		id, ok := sel.X.(*ast.Ident)
		if !ok {
			return true
		}
		p, ok := local[id.Name]
		if !ok {
			return true
		}
		for i, b := range boundaries {
			for _, fn := range b.calls[p] {
				if sel.Sel.Name == fn {
					out = append(out, finding{i, "uses " + p + "." + fn, fset.Position(sel.Pos()).Line})
				}
			}
		}
		return true
	})
	return out, nil
}

func hasPrefix(rel string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(rel, p) {
			return true
		}
	}
	return false
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found above the test's directory")
		}
		dir = parent
	}
}

func TestBoundaries_HoldAcrossTheRepository(t *testing.T) {
	root := repoRoot(t)
	used := map[[2]int]bool{}
	scanned := 0

	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "vendor", "testdata", "node_modules", "conductor":
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		scanned++
		found, err := findings(p, nil)
		if err != nil {
			t.Errorf("%s: %v", rel, err)
			return nil
		}
		for _, f := range found {
			b := boundaries[f.boundary]
			switch {
			case hasPrefix(rel, b.allowed):
			case isException(rel, f.boundary, used):
			default:
				t.Errorf("%s:%d %s, which only %v may do (%s)", rel, f.line, f.what, b.allowed, b.what)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if scanned < 20 {
		t.Fatalf("only %d source files were scanned: the walk is not looking at the repository", scanned)
	}
	for i, e := range exceptions {
		if !used[[2]int{i, e.boundary}] {
			t.Errorf("the exception for %s (%s) is no longer needed: remove it", e.prefix, boundaries[e.boundary].what)
		}
	}
}

func isException(rel string, boundary int, used map[[2]int]bool) bool {
	for i, e := range exceptions {
		if e.boundary == boundary && strings.HasPrefix(rel, e.prefix) {
			used[[2]int{i, boundary}] = true
			return true
		}
	}
	return false
}

// The scanner must be able to fail: these snippets are judged exactly as the real files are.
func TestBoundaries_TheScannerSeesWhatItShould(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want []string // "<boundary>:<what>"
	}{
		{"exec import", `package x; import "os/exec"; var _ = exec.Command`, []string{"0:imports os/exec"}},
		{"aliased exec import", `package x; import e "os/exec"; var _ = e.Command`, []string{"0:imports os/exec"}},
		{"start process", `package x; import "os"; func f() { os.StartProcess("a", nil, nil) }`, []string{"0:uses os.StartProcess"}},
		{"syscall exec", `package x; import "syscall"; func f() { syscall.Exec("a", nil, nil); syscall.ForkExec("a", nil, nil) }`,
			[]string{"0:uses syscall.Exec", "0:uses syscall.ForkExec"}},
		{"remove", `package x; import "os"; func f() { os.RemoveAll("a"); os.Remove("a") }`,
			[]string{"1:uses os.Remove", "1:uses os.RemoveAll"}},
		{"aliased os", `package x; import o "os"; func f() { o.Rename("a", "b") }`, []string{"1:uses os.Rename"}},
		{"a function value", `package x; import "os"; var rm = os.RemoveAll`, []string{"1:uses os.RemoveAll"}},
		{"unlink", `package x; import "syscall"; func f() { syscall.Unlink("a"); syscall.Rmdir("a") }`,
			[]string{"1:uses syscall.Rmdir", "1:uses syscall.Unlink"}},
		{"harmless os", `package x; import "os"; func f() { os.ReadFile("a"); os.Stat("a"); os.Chtimes("a", nowT, nowT) }`, nil},
		{"words in strings and comments", "package x\n// os.RemoveAll and exec.Command\nvar s = \"os.RemoveAll(\\\"x\\\") os/exec\"", nil},
		{"a local variable called os", `package x; type t struct{}; func (t) RemoveAll() {}; func f() { var os t; os.RemoveAll() }`, nil},
		{"a different package with the same function name", `package x; import "example.com/os"; func f() { os.RemoveAll("a") }`, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			found, err := findings("x.go", c.src)
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, f := range found {
				got = append(got, string(rune('0'+f.boundary))+":"+f.what)
			}
			sort.Strings(got)
			want := append([]string(nil), c.want...)
			sort.Strings(want)
			if strings.Join(got, "|") != strings.Join(want, "|") {
				t.Errorf("findings = %v, want %v", got, want)
			}
		})
	}
}
