package modules

import (
	"os/exec"
	"strings"

	"github.com/david-saint/cmm/pkg/cmm"
)

type commandRunner interface {
	Run(name string, arg ...string) (string, error)
}

type realRunner struct{}

func (r *realRunner) Run(name string, arg ...string) (string, error) {
	out, err := exec.Command(name, arg...).Output()
	return string(out), err
}

type TimeMachineModule struct {
	runner commandRunner
}

func NewTimeMachineModule() *TimeMachineModule {
	return &TimeMachineModule{
		runner: &realRunner{},
	}
}

func (m *TimeMachineModule) Name() string {
	return "Time Machine Snapshots"
}

func (m *TimeMachineModule) Description() string {
	return "Local snapshots created by Time Machine. Deleting them can reclaim significant space."
}

func (m *TimeMachineModule) Category() string {
	return "Harsh"
}

func (m *TimeMachineModule) Available() bool {
	return true
}

func (m *TimeMachineModule) Scan() ([]cmm.FileItem, error) {
	// tmutil listlocalsnapshots /
	out, err := m.runner.Run("tmutil", "listlocalsnapshots", "/")
	if err != nil {
		return nil, err
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	var items []cmm.FileItem
	for _, line := range lines {
		if line == "" {
			continue
		}
		// Example output line: com.apple.TimeMachine.2023-05-01-123456.local
		// tmutil output sometimes contains headers or other text, but usually it's just the names.
		// We'll take the last part of the space-separated line if needed.
		parts := strings.Fields(line)
		if len(parts) == 0 {
			continue
		}
		snapshotName := parts[len(parts)-1]
		if !strings.HasPrefix(snapshotName, "com.apple.TimeMachine") {
			continue
		}

		items = append(items, cmm.FileItem{
			Path: snapshotName,
			Size: 0, // tmutil doesn't easily give size per snapshot
			Type: "snapshot",
		})
	}

	return items, nil
}

func (m *TimeMachineModule) Delete(items []cmm.FileItem) (int64, error) {
	var totalFreed int64
	for _, item := range items {
		// tmutil deletelocalsnapshots <snapshot_date>
		// The snapshot name is like com.apple.TimeMachine.2023-05-01-123456.local
		// tmutil deletelocalsnapshots 2023-05-01-123456
		parts := strings.Split(item.Path, ".")
		if len(parts) < 4 {
			continue
		}
		datePart := parts[3]
		
		_, err := m.runner.Run("tmutil", "deletelocalsnapshots", datePart)
		if err != nil {
			return totalFreed, err
		}
		totalFreed += item.Size // Size is 0 for snapshots currently
	}
	return totalFreed, nil
}
