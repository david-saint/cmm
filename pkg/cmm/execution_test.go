package cmm

import (
	"errors"
	"testing"
)

type executionMockModule struct {
	name  string
	res   DeleteResult
	err   error
	calls [][]FileItem
}

func (m *executionMockModule) Name() string              { return m.name }
func (m *executionMockModule) Description() string       { return "mock" }
func (m *executionMockModule) Category() string          { return "Recommended" }
func (m *executionMockModule) Scan() ([]FileItem, error) { return nil, nil }
func (m *executionMockModule) Delete(items []FileItem) (DeleteResult, error) {
	m.calls = append(m.calls, items)
	return m.res, m.err
}

func TestExecutionEngine_DryRunNeverCallsDelete(t *testing.T) {
	m := &executionMockModule{name: "m", res: DeleteResult{Freed: 100}}
	results := []ModuleResult{{Module: m, Items: []FileItem{{Path: "p1", Size: 100}}}}

	outcomes, err := NewExecutionEngine(true).Execute(results)
	if err != nil || len(outcomes) != 0 {
		t.Fatalf("a dry run does nothing and reports nothing: %v, %v", outcomes, err)
	}
	if len(m.calls) != 0 {
		t.Error("a dry run must never call Delete")
	}
}

func TestExecutionEngine_ARealRunReportsEveryModuleInOrder(t *testing.T) {
	a := &executionMockModule{name: "a", res: DeleteResult{Freed: 100}}
	b := &executionMockModule{name: "b", res: DeleteResult{Freed: 50, Skipped: 1, Failed: 2, Notes: []string{"why"}}}
	itemsA := []FileItem{{Path: "p1", Size: 100}}
	itemsB := []FileItem{{Path: "p2", Size: 200}, {Path: "p3", Size: 300}}

	outcomes, err := NewExecutionEngine(false).Execute([]ModuleResult{{Module: a, Items: itemsA}, {Module: b, Items: itemsB}})
	if err != nil {
		t.Fatalf("Execute() failed: %v", err)
	}
	if len(outcomes) != 2 || outcomes[0].Module != Module(a) || outcomes[1].Module != Module(b) {
		t.Fatalf("one outcome per module, in order: %+v", outcomes)
	}
	if outcomes[0].Result.Freed != 100 || outcomes[1].Result.Skipped != 1 || outcomes[1].Result.Failed != 2 || outcomes[1].Result.Notes[0] != "why" {
		t.Errorf("each module's own result must come through unchanged: %+v", outcomes)
	}
	if len(a.calls) != 1 || len(a.calls[0]) != 1 || len(b.calls) != 1 || len(b.calls[0]) != 2 {
		t.Errorf("each module is asked to delete its own items: %v %v", a.calls, b.calls)
	}
	if got := TotalFreed(outcomes); got != 150 {
		t.Errorf("TotalFreed = %d, want 150", got)
	}
}

func TestExecutionEngine_AFailingModuleDoesNotStopTheOthers(t *testing.T) {
	boom, bang := errors.New("boom"), errors.New("bang")
	a := &executionMockModule{name: "a", res: DeleteResult{Freed: 10}, err: boom}
	b := &executionMockModule{name: "b", res: DeleteResult{Freed: 20}}
	c := &executionMockModule{name: "c", err: bang}
	results := []ModuleResult{{Module: a, Items: []FileItem{{Path: "1"}}}, {Module: b, Items: []FileItem{{Path: "2"}}}, {Module: c, Items: []FileItem{{Path: "3"}}}}

	outcomes, err := NewExecutionEngine(false).Execute(results)
	if len(b.calls) != 1 || len(c.calls) != 1 {
		t.Fatalf("every module must be tried even after one fails: b=%d c=%d", len(b.calls), len(c.calls))
	}
	if !errors.Is(err, boom) || !errors.Is(err, bang) {
		t.Errorf("every error must be returned together, got %v", err)
	}
	if len(outcomes) != 3 || !errors.Is(outcomes[0].Err, boom) || outcomes[1].Err != nil || !errors.Is(outcomes[2].Err, bang) {
		t.Errorf("each outcome carries its own error: %+v", outcomes)
	}
	if got := TotalFreed(outcomes); got != 30 {
		t.Errorf("what a failing module did free still counts: %d, want 30", got)
	}
}
