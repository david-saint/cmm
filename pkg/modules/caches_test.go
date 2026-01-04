package modules

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCachesModule_Scan(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "cmm-caches-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create mock cache directories
	apps := []string{"com.google.Chrome", "com.spotify.client", "random.app"}
	for _, app := range apps {
		appDir := filepath.Join(tmpDir, app)
		if err := os.MkdirAll(appDir, 0755); err != nil {
			t.Fatalf("failed to create mock app dir %q: %v", app, err)
		}
		if err := os.WriteFile(filepath.Join(appDir, "cache.db"), []byte("data"), 0644); err != nil {
			t.Fatalf("failed to create mock cache file: %v", err)
		}
	}

	m := &CachesModule{
		CachesPath: tmpDir,
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	// For now, let's assume it picks all directories in Caches
	if len(items) != 3 {
		t.Errorf("expected 3 items, got %d", len(items))
	}
}
