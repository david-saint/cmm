package modules

import (
	"os"
	"path/filepath"

	"github.com/david-saint/cmm/pkg/cmm"
)

type LogsModule struct {
	Paths []string
}

func NewLogsModule() *LogsModule {
	home, _ := os.UserHomeDir()
	return &LogsModule{
		Paths: []string{
			filepath.Join(home, "Library/Logs"),
			"/Library/Logs",
		},
	}
}

func (m *LogsModule) Name() string {
	return "System Logs"
}

func (m *LogsModule) Description() string {
	return "Application and system logs from user and global directories."
}

func (m *LogsModule) Category() string {
	return "Recommended"
}

func (m *LogsModule) Available() bool {
	return true
}

func (m *LogsModule) Scan() ([]cmm.FileItem, error) {
	var items []cmm.FileItem

	for _, basePath := range m.Paths {
		entries, err := os.ReadDir(basePath)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, err
		}

		for _, entry := range entries {
			path := filepath.Join(basePath, entry.Name())
			size := m.calculateSize(path)
			
			itemType := "file"
			if entry.IsDir() {
				itemType = "dir"
			}

			items = append(items, cmm.FileItem{
				Path: path,
				Size: size,
				Type: itemType,
			})
		}
	}

	return items, nil
}

func (m *LogsModule) calculateSize(path string) int64 {
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

func (m *LogsModule) Delete(items []cmm.FileItem) (int64, error) {
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
