// Package sizer measures how much disk a path really uses.
//
// It reports allocated bytes (st_blocks * 512, like du), not apparent sizes, so a sparse file such as a
// virtual machine disk counts what it occupies. Hard links are counted once, symbolic links are not followed
// and directories on another filesystem are not entered (like du -x), which keeps mounted disk images and
// virtual mounts from inflating the result. APFS clones share blocks and cannot be detected from userland, so
// a clone is counted in full; callers should treat sizes as upper bounds.
package sizer

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// Result is what Measure found.
type Result struct {
	Bytes       int64 // allocated bytes
	Files       int   // regular files counted
	Unreadable  int   // entries that could not be read; their size is missing from Bytes
	OtherDevice int   // directories on another filesystem that were not entered
}

type fileStat struct {
	Dev    uint64
	Ino    uint64
	Nlink  uint64
	Blocks int64
}

// statOf extracts the numbers sizer needs. It is a variable so tests can simulate a second filesystem.
var statOf = func(info fs.FileInfo) (fileStat, bool) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fileStat{}, false
	}
	return fileStat{Dev: uint64(st.Dev), Ino: st.Ino, Nlink: uint64(st.Nlink), Blocks: st.Blocks}, true
}

type inodeKey struct{ dev, ino uint64 }

// Measure walks path and returns its allocated size. A missing root is an error; unreadable entries below
// it are counted in Result.Unreadable and skipped.
func Measure(path string) (Result, error) {
	rootInfo, err := os.Lstat(path)
	if err != nil {
		return Result{}, err
	}
	root, ok := statOf(rootInfo)
	if !ok {
		return Result{}, fmt.Errorf("sizer: no stat data for %s", path)
	}

	var res Result
	seen := make(map[inodeKey]struct{})

	walkErr := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			// A directory that cannot be listed: its own entry was already counted by the first call.
			res.Unreadable++
			return nil
		}
		info, err := d.Info()
		if err != nil {
			res.Unreadable++
			return nil
		}
		st, ok := statOf(info)
		if !ok {
			res.Unreadable++
			return nil
		}
		if d.IsDir() && st.Dev != root.Dev {
			res.OtherDevice++
			return fs.SkipDir
		}
		if st.Nlink > 1 && !d.IsDir() {
			k := inodeKey{st.Dev, st.Ino}
			if _, dup := seen[k]; dup {
				return nil
			}
			seen[k] = struct{}{}
		}
		res.Bytes += st.Blocks * 512
		if info.Mode().IsRegular() {
			res.Files++
		}
		return nil
	})
	return res, walkErr
}

// Size is Measure without the details.
func Size(path string) (int64, error) {
	res, err := Measure(path)
	return res.Bytes, err
}
