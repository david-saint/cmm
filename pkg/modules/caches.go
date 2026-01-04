package modules

import (
	"os"
	"path/filepath"

	"github.com/david-saint/cmm/pkg/cmm"
)

type CachesModule struct {
	CachesPath string
}

func NewCachesModule() *CachesModule {
	home, _ := os.UserHomeDir()
	return &CachesModule{
		CachesPath: filepath.Join(home, "Library/Caches"),
	}
}

func (m *CachesModule) Name() string {
	return "User Caches"
}

func (m *CachesModule) Description() string {
	return "Temporary files created by applications to speed up operations."
}

func (m *CachesModule) Category() string {
	return "Recommended"
}

func (m *CachesModule) Scan() ([]cmm.FileItem, error) {
	entries, err := os.ReadDir(m.CachesPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var items []cmm.FileItem
	for _, entry := range entries {
		path := filepath.Join(m.CachesPath, entry.Name())
		
		size := m.calculateSize(path)
		
		items = append(items, cmm.FileItem{
			Path: path,
			Size: size,
		})
	}

	return items, nil
}

func (m *CachesModule) calculateSize(path string) int64 {
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

func (m *CachesModule) Delete(items []cmm.FileItem) (int64, error) {
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
