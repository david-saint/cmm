package sys

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestExecRunner_Success(t *testing.T) {
	res, err := ExecRunner{}.Run(context.Background(), "echo", "hello")
	if err != nil {
		t.Fatalf("Run() failed: %v", err)
	}
	if res.ExitCode != 0 {
		t.Errorf("expected exit code 0, got %d", res.ExitCode)
	}
	if strings.TrimSpace(res.Stdout) != "hello" {
		t.Errorf("unexpected stdout %q", res.Stdout)
	}
}

func TestExecRunner_NonZeroExitIsNotAnError(t *testing.T) {
	res, err := ExecRunner{}.Run(context.Background(), "sh", "-c", "echo out; echo err 1>&2; exit 3")
	if err != nil {
		t.Fatalf("a non-zero exit must be reported in Result, not as an error: %v", err)
	}
	if res.ExitCode != 3 {
		t.Errorf("expected exit code 3, got %d", res.ExitCode)
	}
	if res.Stdout != "out\n" || res.Stderr != "err\n" {
		t.Errorf("unexpected output: stdout=%q stderr=%q", res.Stdout, res.Stderr)
	}
}

func TestExecRunner_MissingBinary(t *testing.T) {
	_, err := ExecRunner{}.Run(context.Background(), "cmm-no-such-binary-xyz")
	if err == nil {
		t.Fatal("expected an error when the command cannot be started")
	}
}

func TestExecRunner_ContextTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := ExecRunner{}.Run(ctx, "sleep", "5")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected context.DeadlineExceeded, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("the command was not stopped promptly (%v)", elapsed)
	}
}

func TestExecRunner_ExtraEnvironment(t *testing.T) {
	res, err := ExecRunner{Env: []string{"CMM_TEST_VAR=yes"}}.Run(context.Background(), "sh", "-c", "echo $CMM_TEST_VAR")
	if err != nil {
		t.Fatalf("Run() failed: %v", err)
	}
	if strings.TrimSpace(res.Stdout) != "yes" {
		t.Errorf("extra environment variable not passed, stdout=%q", res.Stdout)
	}
}
