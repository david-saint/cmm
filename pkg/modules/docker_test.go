package modules

import (
	"fmt"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/cmm"
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

	if items != nil {
		t.Errorf("expected nil items when Docker is not installed, got %v", items)
	}
}

func TestDockerModule_Scan_Parsing(t *testing.T) {
	mockOutput := "Images\t10.5GB\t1.2GB (11%)\n" +
		"Containers\t500MB\t100MB (20%)\n" +
		"Local Volumes\t2.0GB\t500MB\n" +
		"Build Cache\t5.5GB\t2.0GB (36%)"

	m := &DockerModule{
		isDockerInstalled: func() bool { return true },
		runCommand: func(name string, arg ...string) (string, error) {
			if name == "docker" && len(arg) > 1 && arg[0] == "system" && arg[1] == "df" {
				return mockOutput, nil
			}
			return "", nil
		},
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	if len(items) != 4 {
		t.Fatalf("expected 4 items, got %d", len(items))
	}

	expectedPaths := map[string]bool{
		"Images":        true,
		"Containers":    true,
		"Local Volumes": true,
		"Build Cache":   true,
	}

	for _, item := range items {
		if !expectedPaths[item.Path] {
			t.Errorf("unexpected item path: %s", item.Path)
		}
		if item.Size == 0 {
			t.Errorf("expected non-zero size for %s", item.Path)
		}
	}
}

func TestParseDockerSize(t *testing.T) {
	tests := []struct {
		input    string
		expected int64
	}{
		{"0B", 0},
		{"100B", 100},
		{"1KB", 1024},
		{"1.5MB", 1572864},
		{"1.2GB", 1288490188},
		{"  1.2GB (10%) ", 1288490188},
	}

	for _, tt := range tests {
		got, _ := parseDockerSize(tt.input)
		if got != tt.expected {
			t.Errorf("parseDockerSize(%q) = %d, want %d", tt.input, got, tt.expected)
		}
	}
}

func TestDockerModule_Delete(t *testing.T) {
	commands := []string{}
	m := &DockerModule{
		runCommand: func(name string, arg ...string) (string, error) {
			commands = append(commands, fmt.Sprintf("%s %s", name, strings.Join(arg, " ")))
			return "", nil
		},
	}

	items := []cmm.FileItem{
		{Path: "Images", Size: 1000},
		{Path: "Containers", Size: 500},
	}

	freed, err := m.Delete(items)
	if err != nil {
		t.Fatalf("Delete() failed: %v", err)
	}

	if freed != 1500 {
		t.Errorf("expected 1500 freed, got %d", freed)
	}

	expectedCommands := []string{
		"docker system prune -f",
		"docker volume prune -f",
	}

	if len(commands) != len(expectedCommands) {
		t.Fatalf("expected %d commands, got %d", len(expectedCommands), len(commands))
	}

	for i, cmd := range expectedCommands {
		if commands[i] != cmd {
			t.Errorf("expected command %d to be %q, got %q", i, cmd, commands[i])
		}
	}
}