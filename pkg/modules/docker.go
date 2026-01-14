package modules

type DockerModule struct {
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
