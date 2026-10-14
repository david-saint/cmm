// Package sys wraps everything cmm needs from the operating system (external commands, the clock and
// the per-user directories) behind small interfaces, so that rules can be tested against fakes and a test
// can never touch the real machine by accident.
package sys

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"time"
)

// Result is the outcome of a command that ran to completion.
type Result struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Runner runs an external command.
//
// A non-zero exit status is NOT an error: it is reported in Result.ExitCode, because tools such as lsof and
// pgrep use exit codes to answer yes/no questions. The error is non-nil only when the command could not be
// started or the context ended before it finished.
type Runner interface {
	Run(ctx context.Context, name string, args ...string) (Result, error)
}

// ExecRunner runs real commands. Env lists extra KEY=VALUE variables added to the inherited environment.
type ExecRunner struct {
	Env []string
}

// Run implements Runner.
func (r ExecRunner) Run(ctx context.Context, name string, args ...string) (Result, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if len(r.Env) > 0 {
		cmd.Env = append(os.Environ(), r.Env...)
	}
	// If a child process keeps the pipes open after the command is killed, do not wait for it forever.
	cmd.WaitDelay = 2 * time.Second

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	res := Result{Stdout: stdout.String(), Stderr: stderr.String()}

	if ctxErr := ctx.Err(); ctxErr != nil {
		return res, ctxErr
	}
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			res.ExitCode = exitErr.ExitCode()
			return res, nil
		}
		return res, err
	}
	return res, nil
}
