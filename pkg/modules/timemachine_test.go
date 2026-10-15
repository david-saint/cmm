package modules

import (
	"errors"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/cmm"
)

type mockRunner struct {
	output string
	err    error
}

func (r *mockRunner) Run(name string, arg ...string) (string, error) {
	return r.output, r.err
}

// funcRunner lets a test decide, per call, what tmutil says.
type funcRunner func(name string, arg ...string) (string, error)

func (f funcRunner) Run(name string, arg ...string) (string, error) { return f(name, arg...) }

func TestTimeMachineModule_Scan(t *testing.T) {
	mockOutput := "com.apple.TimeMachine.2026-01-01-120000.local\ncom.apple.TimeMachine.2026-01-02-120000.local"
	runner := &mockRunner{output: mockOutput}

	m := &TimeMachineModule{
		runner: runner,
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	if len(items) != 2 {
		t.Errorf("expected 2 items, got %d", len(items))
	}

	if items[0].Path != "com.apple.TimeMachine.2026-01-01-120000.local" {
		t.Errorf("expected path %q, got %q", "com.apple.TimeMachine.2026-01-01-120000.local", items[0].Path)
	}
}

func TestTimeMachineModule_Delete(t *testing.T) {
	var calls []string
	m := &TimeMachineModule{runner: funcRunner(func(name string, arg ...string) (string, error) {
		calls = append(calls, name+" "+strings.Join(arg, " "))
		return "", nil
	})}

	res, err := m.Delete([]cmm.FileItem{{Path: "com.apple.TimeMachine.2026-01-01-120000.local", Size: 100}})
	if err != nil {
		t.Fatalf("Delete() failed: %v", err)
	}
	if res.Freed != 100 || res.Skipped != 0 || res.Failed != 0 || len(res.Notes) != 0 {
		t.Errorf("unexpected result: %+v", res)
	}
	if len(calls) != 1 || calls[0] != "tmutil deletelocalsnapshots 2026-01-01-120000" {
		t.Errorf("tmutil should be given only the date part of the snapshot name: %v", calls)
	}
}

func TestTimeMachineModule_AFailingSnapshotDoesNotStopTheOthers(t *testing.T) {
	var calls []string
	m := &TimeMachineModule{runner: funcRunner(func(name string, arg ...string) (string, error) {
		calls = append(calls, arg[len(arg)-1])
		if arg[len(arg)-1] == "2026-01-01-120000" {
			return "", errors.New("exit status 1")
		}
		return "", nil
	})}
	items := []cmm.FileItem{
		{Path: "com.apple.TimeMachine.2026-01-01-120000.local", Size: 10},
		{Path: "com.apple.TimeMachine.2026-01-02-120000.local", Size: 20},
	}

	res, err := m.Delete(items)
	if err != nil {
		t.Fatalf("one failing snapshot is reported in the result, not as an error: %v", err)
	}
	if len(calls) != 2 {
		t.Errorf("every snapshot must be tried: %v", calls)
	}
	if res.Freed != 20 || res.Failed != 1 || res.Skipped != 0 {
		t.Errorf("only the deleted snapshot counts as freed: %+v", res)
	}
	if len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "2026-01-01-120000") || !strings.Contains(res.Notes[0], "exit status 1") {
		t.Errorf("the note should name the snapshot and the reason: %q", res.Notes)
	}
}

func TestTimeMachineModule_ANameItDoesNotUnderstandIsSkippedNotSilentlyDropped(t *testing.T) {
	called := false
	m := &TimeMachineModule{runner: funcRunner(func(string, ...string) (string, error) { called = true; return "", nil })}

	res, err := m.Delete([]cmm.FileItem{{Path: "not-a-snapshot", Size: 5}})
	if err != nil {
		t.Fatal(err)
	}
	if called {
		t.Error("tmutil must not be called with a name that cannot be turned into a snapshot date")
	}
	if res.Skipped != 1 || res.Freed != 0 || len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "not-a-snapshot") {
		t.Errorf("the item should be reported as skipped with its name: %+v", res)
	}
}
