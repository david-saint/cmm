package sys

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestFakeRunner_StubbedAndRecorded(t *testing.T) {
	f := NewFakeRunner()
	f.Stub(Result{Stdout: "x", ExitCode: 1}, nil, "lsof", "-w", "+D", "/a")

	res, err := f.Run(context.Background(), "lsof", "-w", "+D", "/a")
	if err != nil {
		t.Fatalf("Run() failed: %v", err)
	}
	if res.Stdout != "x" || res.ExitCode != 1 {
		t.Errorf("unexpected result %+v", res)
	}

	calls := f.Calls()
	if len(calls) != 1 || calls[0].Name != "lsof" || strings.Join(calls[0].Args, " ") != "-w +D /a" {
		t.Errorf("call not recorded correctly: %+v", calls)
	}
}

func TestFakeRunner_UnstubbedCallFailsLoudly(t *testing.T) {
	f := NewFakeRunner()
	_, err := f.Run(context.Background(), "rm", "-rf", "/")
	if err == nil || !strings.Contains(err.Error(), "unexpected command") {
		t.Fatalf("an unstubbed command must fail loudly, got %v", err)
	}
	if len(f.Calls()) != 1 {
		t.Errorf("the unexpected call should still be recorded")
	}
}

func TestFakeRunner_PrefixStub(t *testing.T) {
	f := NewFakeRunner()
	f.StubPrefix(Result{ExitCode: 1}, nil, "pgrep", "-f")

	res, err := f.Run(context.Background(), "pgrep", "-f", "anything at all")
	if err != nil || res.ExitCode != 1 {
		t.Errorf("prefix stub not matched: res=%+v err=%v", res, err)
	}
	if _, err := f.Run(context.Background(), "pgrep", "-x", "go"); err == nil {
		t.Errorf("a different argument prefix must not match")
	}
}

func TestFakeRunner_ExactBeatsPrefix(t *testing.T) {
	f := NewFakeRunner()
	f.StubPrefix(Result{Stdout: "prefix"}, nil, "brew")
	f.Stub(Result{Stdout: "exact"}, nil, "brew", "cleanup", "-n")

	res, _ := f.Run(context.Background(), "brew", "cleanup", "-n")
	if res.Stdout != "exact" {
		t.Errorf("exact stub should win over prefix stub, got %q", res.Stdout)
	}
	res, _ = f.Run(context.Background(), "brew", "list")
	if res.Stdout != "prefix" {
		t.Errorf("prefix stub should answer the rest, got %q", res.Stdout)
	}
}

func TestFakeRunner_StubbedError(t *testing.T) {
	f := NewFakeRunner()
	boom := errors.New("boom")
	f.Stub(Result{}, boom, "xcrun", "simctl", "list")

	if _, err := f.Run(context.Background(), "xcrun", "simctl", "list"); !errors.Is(err, boom) {
		t.Errorf("expected the stubbed error, got %v", err)
	}
}

func TestFakeRunner_ConcurrentUse(t *testing.T) {
	f := NewFakeRunner()
	f.StubPrefix(Result{}, nil, "pgrep")

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = f.Run(context.Background(), "pgrep", "-x", "go")
		}()
	}
	wg.Wait()
	if len(f.Calls()) != 20 {
		t.Errorf("expected 20 recorded calls, got %d", len(f.Calls()))
	}
}
