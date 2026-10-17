package engine

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/david-saint/cmm/pkg/policy"
)

// remove deletes path through the injected function (or os.RemoveAll), behind the test safety net.
func (e *Engine) remove(path string) error {
	fn := e.Remove
	if fn == nil {
		fn = os.RemoveAll
	}
	return guardedRemove(path, fn)
}

func defaultRemove(path string) error { return guardedRemove(path, os.RemoveAll) }

// guardedRemove is the last line of defence: while a test binary is running, a deletion outside a temporary
// directory is a bug in the test (or in the code under test) and panics instead of touching real files.
// testing.Testing() is false in every normal build, so this costs nothing in production.
func guardedRemove(path string, fn func(string) error) error {
	if testing.Testing() {
		mustBeTempPath(path)
	}
	return fn(path)
}

func mustBeTempPath(path string) {
	clean := filepath.Clean(path)
	for _, root := range []string{os.TempDir(), "/var/folders", "/private/var/folders"} {
		if policy.Under(clean, root) {
			return
		}
	}
	panic(fmt.Sprintf("engine: refusing to delete %q while testing: it is not inside a temporary directory", path))
}
