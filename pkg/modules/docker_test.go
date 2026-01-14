package modules

import (
	"testing"
)

func TestDockerModule_Basics(t *testing.T) {
	m := &DockerModule{}

	if m.Name() != "Docker Cleanup" {
		t.Errorf("expected name 'Docker Cleanup', got %q", m.Name())
	}

	if m.Category() != "Advanced/Optional" {
		t.Errorf("expected category 'Advanced/Optional', got %q", m.Category())
	}

	if m.Description() == "" {
		t.Error("expected non-empty description")
	}
}

func TestDockerModule_Scan_NotInstalled(t *testing.T) {
	m := &DockerModule{
		isDockerInstalled: func() bool { return false },
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	if len(items) != 0 {
		t.Errorf("expected 0 items when Docker is not installed, got %d", len(items))
	}
}

func TestDockerModule_Scan_Installed(t *testing.T) {
	// This test assumes Scan returns empty list for now (as implementation is not done),
	// but we want to ensure it DOESN'T return early if installed.
	// Since we haven't implemented the actual scan logic, we can't easily distinguish 
	// "returned early" from "returned empty list".
	// However, we can verify that the check IS called.
	
	called := false
	m := &DockerModule{
		isDockerInstalled: func() bool { 
			called = true
			return true 
		},
	}

	_, _ = m.Scan()

	if !called {
		t.Error("expected isDockerInstalled check to be called")
	}
}