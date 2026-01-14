package modules

import (
	"os/exec"

	"github.com/david-saint/cmm/pkg/cmm"
)

type DockerModule struct {
	isDockerInstalled func() bool
}

func NewDockerModule() *DockerModule {
	return &DockerModule{
		isDockerInstalled: func() bool {
			_, err := exec.LookPath("docker")
			return err == nil
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

func (m *DockerModule) Scan() ([]cmm.FileItem, error) {
	if m.isDockerInstalled != nil && !m.isDockerInstalled() {
		return nil, nil
	}
	
	// TODO: Implement actual scanning
	return []cmm.FileItem{}, nil
}