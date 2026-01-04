package modules

import (
	"os/exec"

	"github.com/david-saint/cmm/pkg/cmm"
)

type HomebrewModule struct {
	brewPath string
}

func NewHomebrewModule() *HomebrewModule {
	path, err := exec.LookPath("brew")
	if err != nil {
		return nil
	}
	return &HomebrewModule{
		brewPath: path,
	}
}

func (m *HomebrewModule) Name() string {
	return "Homebrew"
}

func (m *HomebrewModule) Description() string {
	return "Stale lock files, outdated downloads, and old versions of formulae."
}

func (m *HomebrewModule) Category() string {
	return "Recommended"
}

func (m *HomebrewModule) Scan() ([]cmm.FileItem, error) {
	// Homebrew cleanup dry-run can be slow and output is complex.
	// We provide a summary item.
	return []cmm.FileItem{
		{
			Path: "Homebrew Artifacts",
			Size: 0, // Size is unknown until cleanup runs
			Type: "summary",
		},
	}, nil
}

func (m *HomebrewModule) Delete(items []cmm.FileItem) (int64, error) {
	// brew cleanup --prune=all
	cmd := exec.Command(m.brewPath, "cleanup", "--prune=all")
	err := cmd.Run()
	if err != nil {
		return 0, err
	}
	
	// Homebrew doesn't easily report total bytes freed in a machine-readable way via command exit.
	// We return 0 for now, or could attempt to parse output if we really wanted to.
	return 0, nil
}
