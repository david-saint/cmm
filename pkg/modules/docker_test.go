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
