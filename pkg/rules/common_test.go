package rules

import (
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

func TestExpand_OnlyCleanTemplatesUnderHomeOrTmp(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)

	for tmpl, want := range map[string]string{
		"~/a":           sb.Home("a"),
		"~/a/b c/.d":    sb.Home("a", "b c", ".d"),
		"{tmp}/a":       sb.Tmp("a"),
		"{tmp}/jest_dx": sb.Tmp("jest_dx"),
	} {
		got, ok := expand(d, tmpl)
		if !ok || got != want {
			t.Errorf("expand(%q) = %q, %v; want %q", tmpl, got, ok, want)
		}
	}

	for _, tmpl := range []string{
		"", "~", "~/", "{tmp}", "{tmp}/", "/etc/passwd", "a/b", "~a/b", "tmp/a", "$HOME/a", "{TMP}/a",
		"~/../x", "~/a/../../x", "~/a/..", "{tmp}/../x", "~/./a", "~//a", "~/a//b", "~/a/", "{tmp}//a",
	} {
		if got, ok := expand(d, tmpl); ok {
			t.Errorf("expand(%q) = %q, must be refused", tmpl, got)
		}
	}
}

func TestExpand_NeedsTheRootsToBeKnown(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	d.Env.Home = ""
	if _, ok := expand(d, "~/a"); ok {
		t.Error("without a home folder ~/ means nothing")
	}
	d = depsFor(sb)
	d.Env.TmpDir = ""
	if _, ok := expand(d, "{tmp}/a"); ok {
		t.Error("without a temp folder {tmp}/ means nothing")
	}
	if _, ok := expandRoot(d, "{tmp}"); ok {
		t.Error("without a temp folder {tmp} means nothing")
	}
}

func TestExpandRoot_AlsoAcceptsTheBareTempFolder(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	if got, ok := expandRoot(d, "{tmp}"); !ok || got != sb.Env.TmpDir {
		t.Errorf("expandRoot({tmp}) = %q, %v", got, ok)
	}
	if got, ok := expandRoot(d, "~/lane-builds"); !ok || got != sb.Home("lane-builds") {
		t.Errorf("expandRoot(~/lane-builds) = %q, %v", got, ok)
	}
	for _, tmpl := range []string{"", "~", "~/", "{tmp}/", "/", "~/../x", "{tmp}x"} {
		if got, ok := expandRoot(d, tmpl); ok {
			t.Errorf("expandRoot(%q) = %q, must be refused", tmpl, got)
		}
	}
}

func TestBlockedBy(t *testing.T) {
	spec := []guard.ProcSpec{{Exact: "go"}}
	run := func(res sys.Result, err error) error {
		sb := systest.NewSandbox(t)
		sb.Runner.Stub(res, err, "pgrep", "-x", "go")
		return blockedBy(ctx, depsFor(sb), "Go build cache", spec, "a go command is running")
	}

	if err := blockedBy(ctx, depsFor(systest.NewSandbox(t)), "x", nil, "never asked"); err != nil {
		t.Errorf("no processes to look for means nothing blocks: %v", err)
	}
	if err := run(sys.Result{ExitCode: 1}, nil); err != nil {
		t.Errorf("not running must not block: %v", err)
	}
	if err := run(sys.Result{ExitCode: 0}, nil); err == nil || err.Error() != "Go build cache: a go command is running" {
		t.Errorf("a running process must block with its reason, got %v", err)
	}
	for name, c := range map[string]struct {
		res sys.Result
		err error
	}{
		"pgrep failing":   {sys.Result{ExitCode: 2}, nil},
		"cannot be run":   {sys.Result{}, errString("no such file")},
		"killed (status)": {sys.Result{ExitCode: 137}, nil},
	} {
		err := run(c.res, c.err)
		if err == nil || !strings.Contains(err.Error(), "could not check whether the tools using it are running") {
			t.Errorf("%s: a question that cannot be answered must block, got %v", name, err)
		}
	}
}

type errString string

func (e errString) Error() string { return string(e) }
