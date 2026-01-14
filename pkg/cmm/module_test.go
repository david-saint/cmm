package cmm

import "testing"

type mockModule struct{}

func (m *mockModule) Name() string                     { return "mock" }
func (m *mockModule) Description() string              { return "mock description" }
func (m *mockModule) Category() string                 { return "Recommended" }
func (m *mockModule) Available() bool                  { return true }
func (m *mockModule) Scan() ([]FileItem, error)        { return nil, nil }
func (m *mockModule) Delete([]FileItem) (int64, error) { return 0, nil }

func TestModuleInterface(t *testing.T) {
	var _ Module = (*mockModule)(nil)
}
