package modules

import (
	"os"
	"path/filepath"

	"github.com/david-saint/cmm/pkg/cmm"
)

type XcodeModule struct {
	DerivedDataPath string
}

func NewXcodeModule() *XcodeModule {
	home, _ := os.UserHomeDir()
	return &XcodeModule{
		DerivedDataPath: filepath.Join(home, "Library/Developer/Xcode/DerivedData"),
	}
}

func (m *XcodeModule) Name() string {
	return "Xcode Derived Data"
}

func (m *XcodeModule) Description() string {
	return "Temporary build artifacts and indexes created by Xcode."
}

func (m *XcodeModule) Category() string {
	return "Recommended"
}

func (m *XcodeModule) Scan() ([]cmm.FileItem, error) {
	entries, err := os.ReadDir(m.DerivedDataPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var items []cmm.FileItem
	for _, entry := range entries {
		path := filepath.Join(m.DerivedDataPath, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		
		size := m.calculateSize(path)
		
		items = append(items, cmm.FileItem{
			Path: path,
			Size: size,
		})
		_ = info // use info if needed
	}

	return items, nil
}

func (m *XcodeModule) calculateSize(path string) int64 {
	var size int64
	_ = filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() {
			size += info.Size()
		}
		return nil
	})
	return size
}

func (m *XcodeModule) Delete(items []cmm.FileItem) (int64, error) {
	var totalFreed int64
	for _, item := range items {
		err := os.RemoveAll(item.Path)
		if err != nil {
			return totalFreed, err
		}
		totalFreed += item.Size
	}
	return totalFreed, nil
}
