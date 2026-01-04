package modules

import (
	"os"
	"path/filepath"
	"testing"
)

func TestXcodeModule_Scan(t *testing.T) {
	// Setup a temporary DerivedData directory
	tmpDir, err := os.MkdirTemp("", "cmm-xcode-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create some mock files
	mockProject := filepath.Join(tmpDir, "TestProject-abc")
	if err := os.MkdirAll(mockProject, 0755); err != nil {
		t.Fatalf("failed to create mock project dir: %v", err)
	}
	
	mockFile := filepath.Join(mockProject, "info.plist")
	if err := os.WriteFile(mockFile, []byte("test"), 0644); err != nil {
		t.Fatalf("failed to create mock file: %v", err)
	}

	m := &XcodeModule{
		DerivedDataPath: tmpDir,
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	if len(items) != 1 {
		t.Errorf("expected 1 item, got %d", len(items))
	}

	if items[0].Path != mockProject {
		t.Errorf("expected path %q, got %q", mockProject, items[0].Path)
	}
}
