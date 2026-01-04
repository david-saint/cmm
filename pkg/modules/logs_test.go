package modules

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/david-saint/cmm/pkg/cmm"
)

func TestLogsModule_Scan(t *testing.T) {
	tmpDir1, _ := os.MkdirTemp("", "cmm-logs-test-1")
	defer os.RemoveAll(tmpDir1)
	tmpDir2, _ := os.MkdirTemp("", "cmm-logs-test-2")
	defer os.RemoveAll(tmpDir2)

	// Create mock logs
	logFiles1 := []string{"system.log", "wifi.log"}
	for _, f := range logFiles1 {
		os.WriteFile(filepath.Join(tmpDir1, f), []byte("log data"), 0644)
	}
	logFiles2 := []string{"app.log"}
	for _, f := range logFiles2 {
		os.WriteFile(filepath.Join(tmpDir2, f), []byte("more log data"), 0644)
	}

	m := &LogsModule{
		Paths: []string{tmpDir1, tmpDir2},
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	expectedCount := 3 // 2 from tmpDir1, 1 from tmpDir2
	if len(items) != expectedCount {
		t.Errorf("expected %d items, got %d", expectedCount, len(items))
	}
}

func TestLogsModule_Delete(t *testing.T) {
	tmpDir, _ := os.MkdirTemp("", "cmm-logs-delete-test")
	defer os.RemoveAll(tmpDir)

	logFile := filepath.Join(tmpDir, "to_delete.log")
	os.WriteFile(logFile, []byte("data"), 0644)

	m := &LogsModule{
		Paths: []string{tmpDir},
	}

	items := []cmm.FileItem{
		{Path: logFile, Size: 4, Type: "file"},
	}

	freed, err := m.Delete(items)
	if err != nil {
		t.Fatalf("Delete() failed: %v", err)
	}

	if freed != 4 {
		t.Errorf("expected 4 bytes freed, got %d", freed)
	}

	if _, err := os.Stat(logFile); !os.IsNotExist(err) {
		t.Errorf("expected file to be deleted, but it still exists")
	}
}

func TestLogsModule_Metadata(t *testing.T) {
	m := &LogsModule{}
	if m.Name() != "System Logs" {
		t.Errorf("unexpected name: %s", m.Name())
	}
	if m.Description() == "" {
		t.Errorf("description should not be empty")
	}
	if m.Category() != "Recommended" {
		t.Errorf("unexpected category: %s", m.Category())
	}
}

func TestNewLogsModule(t *testing.T) {
	m := NewLogsModule()
	if len(m.Paths) == 0 {
		t.Errorf("expected paths to be initialized")
	}
}
