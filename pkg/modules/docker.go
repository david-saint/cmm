package modules

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/david-saint/cmm/pkg/cmm"
)

type DockerModule struct {
	isDockerInstalled func() bool
	runCommand        func(name string, arg ...string) (string, error)
}

func NewDockerModule() *DockerModule {
	return &DockerModule{
		isDockerInstalled: func() bool {
			_, err := exec.LookPath("docker")
			return err == nil
		},
		runCommand: func(name string, arg ...string) (string, error) {
			out, err := exec.Command(name, arg...).Output()
			return string(out), err
		},
	}
}

func (m *DockerModule) Name() string {
	return "Docker Cleanup"
}

func (m *DockerModule) Description() string {
	return "Reclaim space from unused Docker containers, images, and volumes."
}

func (m *DockerModule) Category() string {
	return "Advanced/Optional"
}

func (m *DockerModule) Available() bool {
	if m.isDockerInstalled != nil {
		return m.isDockerInstalled()
	}
	return false
}

func (m *DockerModule) Scan() ([]cmm.FileItem, error) {
	if !m.Available() {
		return nil, nil
	}

	out, err := m.runCommand("docker", "system", "df", "--format", "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}")
	if err != nil {
		return nil, err
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	var items []cmm.FileItem
	for _, line := range lines {
		parts := strings.Split(line, "\t")
		if len(parts) < 3 {
			continue
		}

		category := parts[0]
		// reclaimable can be like "1.2GB (10%)" or "0B (0%)" or "1.2GB"
		reclaimableStr := parts[2]
		if idx := strings.Index(reclaimableStr, "("); idx != -1 {
			reclaimableStr = strings.TrimSpace(reclaimableStr[:idx])
		}

		size, _ := parseDockerSize(reclaimableStr)

		if size > 0 {
			items = append(items, cmm.FileItem{
				Path: category,
				Size: size,
				Type: "docker",
			})
		}
	}

	return items, nil
}

func parseDockerSize(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if idx := strings.Index(s, "("); idx != -1 {
		s = strings.TrimSpace(s[:idx])
	}
	if s == "" || s == "0B" {
		return 0, nil
	}

	var multiplier int64 = 1
	var unit string
	
	if strings.HasSuffix(s, "GB") {
		multiplier = 1024 * 1024 * 1024
		unit = "GB"
	} else if strings.HasSuffix(s, "MB") {
		multiplier = 1024 * 1024
		unit = "MB"
	} else if strings.HasSuffix(s, "KB") {
		multiplier = 1024
		unit = "KB"
	} else if strings.HasSuffix(s, "B") {
		multiplier = 1
		unit = "B"
	}

	numStr := strings.TrimSuffix(s, unit)
	val, err := strconv.ParseFloat(numStr, 64)
	if err != nil {
		return 0, err
	}

	return int64(val * float64(multiplier)), nil
}

func (m *DockerModule) Delete(items []cmm.FileItem) (int64, error) {
	var totalFreed int64
	
	// We run system prune and volume prune as specified
	_, err := m.runCommand("docker", "system", "prune", "-f")
	if err != nil {
		return 0, fmt.Errorf("docker system prune failed: %v", err)
	}

	_, err = m.runCommand("docker", "volume", "prune", "-f")
	if err != nil {
		return 0, fmt.Errorf("docker volume prune failed: %v", err)
	}

	// Calculate what we were supposed to free
	for _, item := range items {
		totalFreed += item.Size
	}

	return totalFreed, nil
}