package engine

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The history and the samples only ever feed what a person is shown. Nothing that decides what may be planned
// or deleted reads them, so a tampered file can change a screen and nothing else. These tests keep it so.

func TestHistory_TheEngineCanOnlyWriteItNeverRead(t *testing.T) {
	if n := reflect.TypeOf((*RunLog)(nil)).Elem().NumMethod(); n != 1 {
		t.Errorf("the engine holds its history through RunLog, which may only append (%d methods)", n)
	}
	if _, ok := reflect.TypeOf((*RunLog)(nil)).Elem().MethodByName("Append"); !ok {
		t.Error("RunLog is the Append interface")
	}
}

// selectorsIn lists the selector names used in a Go file (x.Name), with their lines.
func selectorsIn(t *testing.T, file string) map[string][]int {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, file, nil, parser.SkipObjectResolution)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]int{}
	ast.Inspect(f, func(n ast.Node) bool {
		if sel, ok := n.(*ast.SelectorExpr); ok {
			out[sel.Sel.Name] = append(out[sel.Sel.Name], fset.Position(sel.Pos()).Line)
		}
		return true
	})
	return out
}

func TestHistory_OnlyTheHistoryCodeAndTheHistoryCommandsReadIt(t *testing.T) {
	root := repoRoot(t)
	readers := []string{"Runs", "Samples", "Sample", "HistoryPath", "SamplesPath", "Report"}
	cases := []struct {
		dir   string
		allow map[string]bool // the files that may read
	}{
		{"pkg/engine", map[string]bool{"history.go": true}},
		{"cmd", map[string]bool{"history_cmds.go": true}},
	}
	checked := 0
	for _, c := range cases {
		files, err := filepath.Glob(filepath.Join(root, c.dir, "*.go"))
		if err != nil {
			t.Fatal(err)
		}
		for _, file := range files {
			base := filepath.Base(file)
			if strings.HasSuffix(base, "_test.go") || c.allow[base] {
				continue
			}
			checked++
			sels := selectorsIn(t, file)
			for _, name := range readers {
				// `Report` is also the name of apply's own report type (engine.Report), and `Sample` of the
				// sample type; only calls on a value can read, and none of the decision code has a reason to.
				if lines := sels[name]; len(lines) > 0 && !selectorIsUnrelated(file, name) {
					t.Errorf("%s uses .%s at lines %v: only %v may read the history", filepath.Join(c.dir, base), name, lines, keys(c.allow))
				}
			}
		}
	}
	if checked < 10 {
		t.Fatalf("only %d files were checked: the scan is not looking at the code", checked)
	}
}

// selectorIsUnrelated says whether every use of name in the file is the type engine.Report or engine.Sample (a
// qualified type name), not a call on a value.
func selectorIsUnrelated(file, name string) bool {
	if name != "Report" && name != "Sample" {
		return false
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, file, nil, parser.SkipObjectResolution)
	if err != nil {
		return false
	}
	unrelated := true
	ast.Inspect(f, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == name {
			unrelated = false // called as a function or method
		}
		return true
	})
	return unrelated
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestHistory_NoRuleOrPolicyCodeMentionsTheStateFolder(t *testing.T) {
	root := repoRoot(t)
	for _, dir := range []string{"pkg/rules", "pkg/policy", "pkg/guard", "pkg/sizer"} {
		files, _ := filepath.Glob(filepath.Join(root, dir, "*.go"))
		for _, file := range files {
			if strings.HasSuffix(file, "_test.go") {
				continue
			}
			b, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			// (policy lists ~/.local/state among the folders that can never be a target: that protects the records)
			for _, word := range []string{"history.jsonl", "free.jsonl", "StateDir", "HistoryFile", "SamplesFile", "FileHistory"} {
				if strings.Contains(string(b), word) {
					t.Errorf("%s mentions %q: rules, policy, guards and sizing never look at cmm's own records", filepath.Join(dir, filepath.Base(file)), word)
				}
			}
		}
	}
}
