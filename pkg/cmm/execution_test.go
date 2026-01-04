package cmm

import "testing"

type executionMockModule struct {
	freed int64
}

func (m *executionMockModule) Name() string                     { return "mock" }
func (m *executionMockModule) Description() string              { return "mock" }
func (m *executionMockModule) Category() string                 { return "Recommended" }
func (m *executionMockModule) Scan() ([]FileItem, error)        { return nil, nil }
func (m *executionMockModule) Delete([]FileItem) (int64, error) { return m.freed, nil }

func TestExecutionEngine_Execute(t *testing.T) {
	m := &executionMockModule{freed: 100}
	results := []ModuleResult{
		{Module: m, Items: []FileItem{{Path: "p1", Size: 100}}},
	}

	// Test Dry Run
	engine := NewExecutionEngine(true)
	freed, err := engine.Execute(results)
	if err != nil {
		t.Fatalf("Execute() failed: %v", err)
	}
	if freed != 0 {
		t.Errorf("expected 0 freed in dry run, got %d", freed)
	}

	// Test Real Run
	engine = NewExecutionEngine(false)
	freed, err = engine.Execute(results)
	if err != nil {
		t.Fatalf("Execute() failed: %v", err)
	}
	if freed != 100 {
		t.Errorf("expected 100 freed, got %d", freed)
	}
}
