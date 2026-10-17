package sys

import (
	"context"
	"fmt"
	"strings"
	"sync"
)

// Call records one command a FakeRunner was asked to run.
type Call struct {
	Name string
	Args []string
}

type stub struct {
	res Result
	err error
}

type prefixStub struct {
	name string
	args []string
	stub stub
}

// FakeRunner is a Runner for tests. Only commands that were stubbed succeed; anything else fails loudly with
// "unexpected command", so a rule can never reach a real tool through a fake environment.
type FakeRunner struct {
	mu     sync.Mutex
	exact  map[string]stub
	prefix []prefixStub
	calls  []Call
}

// NewFakeRunner returns an empty FakeRunner.
func NewFakeRunner() *FakeRunner {
	return &FakeRunner{exact: make(map[string]stub)}
}

func key(name string, args []string) string {
	return name + "\x00" + strings.Join(args, "\x00")
}

// Stub answers exactly this command line with res and err.
func (f *FakeRunner) Stub(res Result, err error, name string, args ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.exact[key(name, args)] = stub{res: res, err: err}
}

// StubPrefix answers every command whose name matches and whose arguments start with args. When several
// prefixes match, the longest wins; an exact Stub always wins over a prefix.
func (f *FakeRunner) StubPrefix(res Result, err error, name string, args ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.prefix = append(f.prefix, prefixStub{name: name, args: append([]string(nil), args...), stub: stub{res: res, err: err}})
}

// Calls returns a copy of every command run so far, in order.
func (f *FakeRunner) Calls() []Call {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Call(nil), f.calls...)
}

// Run implements Runner.
func (f *FakeRunner) Run(_ context.Context, name string, args ...string) (Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, Call{Name: name, Args: append([]string(nil), args...)})

	if s, ok := f.exact[key(name, args)]; ok {
		return s.res, s.err
	}

	best := -1
	for i, p := range f.prefix {
		if p.name != name || len(p.args) > len(args) {
			continue
		}
		match := true
		for j, a := range p.args {
			if args[j] != a {
				match = false
				break
			}
		}
		if match && (best < 0 || len(p.args) > len(f.prefix[best].args)) {
			best = i
		}
	}
	if best >= 0 {
		return f.prefix[best].stub.res, f.prefix[best].stub.err
	}
	return Result{}, fmt.Errorf("sys.FakeRunner: unexpected command: %s %s", name, strings.Join(args, " "))
}
