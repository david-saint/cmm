package sizer

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mib = 1 << 20

// block rounding on APFS is 4 KiB; allow a little slack for directory entries and metadata.
const slack = 64 * 1024

func writeFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("x", size)), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMeasure_RegularFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "f")
	writeFile(t, p, mib)

	res, err := Measure(p)
	if err != nil {
		t.Fatalf("Measure() failed: %v", err)
	}
	if res.Bytes < mib || res.Bytes > mib+slack {
		t.Errorf("expected about 1 MiB allocated, got %d", res.Bytes)
	}
	if res.Files != 1 {
		t.Errorf("expected 1 file, got %d", res.Files)
	}
}

func TestMeasure_NestedDirectoriesAreSummed(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a", "one"), mib)
	writeFile(t, filepath.Join(dir, "a", "b", "two"), 2*mib)

	res, err := Measure(dir)
	if err != nil {
		t.Fatalf("Measure() failed: %v", err)
	}
	if res.Bytes < 3*mib || res.Bytes > 3*mib+slack {
		t.Errorf("expected about 3 MiB, got %d", res.Bytes)
	}
	if res.Files != 2 {
		t.Errorf("expected 2 files, got %d", res.Files)
	}
}

// A sparse file reports its apparent size in os.Stat but only allocates the blocks it really uses.
// This is the Docker.raw case: 100 GB apparent, about half that on disk.
func TestMeasure_SparseFileCountsAllocatedNotApparent(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sparse")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(100 * mib); err != nil {
		t.Fatal(err)
	}
	f.Close()

	res, err := Measure(p)
	if err != nil {
		t.Fatalf("Measure() failed: %v", err)
	}
	if res.Bytes > 50*mib {
		t.Skipf("this filesystem does not create sparse files (allocated %d bytes)", res.Bytes)
	}
	if st, _ := os.Stat(p); st.Size() != 100*mib {
		t.Fatalf("test setup is wrong: apparent size %d", st.Size())
	}
	if res.Bytes >= mib {
		t.Errorf("sparse file should allocate far less than its apparent size, got %d", res.Bytes)
	}
}

func TestMeasure_HardLinksAreCountedOnce(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a")
	writeFile(t, a, mib)
	if err := os.Link(a, filepath.Join(dir, "b")); err != nil {
		t.Fatal(err)
	}

	res, err := Measure(dir)
	if err != nil {
		t.Fatalf("Measure() failed: %v", err)
	}
	if res.Bytes < mib || res.Bytes > mib+slack {
		t.Errorf("a hard-linked file must be counted once (about 1 MiB), got %d", res.Bytes)
	}
}

func TestMeasure_SymlinksAreNotFollowed(t *testing.T) {
	dir := t.TempDir()
	big := filepath.Join(dir, "big")
	writeFile(t, filepath.Join(big, "data"), 5*mib)
	holder := filepath.Join(dir, "holder")
	if err := os.MkdirAll(holder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(big, filepath.Join(holder, "link")); err != nil {
		t.Fatal(err)
	}

	res, err := Measure(holder)
	if err != nil {
		t.Fatalf("Measure() failed: %v", err)
	}
	if res.Bytes > slack {
		t.Errorf("the link target must not be counted, got %d bytes", res.Bytes)
	}

	// a symlink given as the root is measured as a link too
	res, err = Measure(filepath.Join(holder, "link"))
	if err != nil {
		t.Fatalf("Measure(link) failed: %v", err)
	}
	if res.Bytes > slack {
		t.Errorf("a root symlink must not be followed, got %d bytes", res.Bytes)
	}
}

func TestMeasure_MissingRootIsAnError(t *testing.T) {
	if _, err := Measure(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("expected an error for a path that does not exist")
	}
}

func TestMeasure_UnreadableDirectoryIsCountedNotFatal(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "ok"), mib)
	locked := filepath.Join(dir, "locked")
	writeFile(t, filepath.Join(locked, "hidden"), mib)
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0o755) // let t.TempDir clean up

	res, err := Measure(dir)
	if err != nil {
		t.Fatalf("an unreadable subdirectory must not fail the measurement: %v", err)
	}
	if res.Unreadable != 1 {
		t.Errorf("expected 1 unreadable entry, got %d", res.Unreadable)
	}
	if res.Bytes < mib {
		t.Errorf("the readable part should still be counted, got %d", res.Bytes)
	}
}

// Like du -x: a directory on another filesystem (a mounted image, a virtual mount) is not entered.
func TestMeasure_DoesNotCrossDevices(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "local"), mib)
	writeFile(t, filepath.Join(dir, "mnt", "foreign"), 5*mib)

	orig := statOf
	statOf = func(info fs.FileInfo) (fileStat, bool) {
		s, ok := orig(info)
		if info.Name() == "mnt" {
			s.Dev++ // pretend this directory is a mount point of another filesystem
		}
		return s, ok
	}
	defer func() { statOf = orig }()

	res, err := Measure(dir)
	if err != nil {
		t.Fatalf("Measure() failed: %v", err)
	}
	if res.Bytes < mib || res.Bytes > mib+slack {
		t.Errorf("only the local file should be counted (about 1 MiB), got %d", res.Bytes)
	}
	if res.OtherDevice != 1 {
		t.Errorf("expected 1 skipped mount point, got %d", res.OtherDevice)
	}
}

func TestSize_MatchesMeasure(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "f"), mib)
	res, _ := Measure(dir)
	n, err := Size(dir)
	if err != nil || n != res.Bytes {
		t.Errorf("Size() = %d, %v; want %d", n, err, res.Bytes)
	}
}
