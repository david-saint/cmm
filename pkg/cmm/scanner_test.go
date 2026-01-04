package cmm

import (
	"testing"
)

type scannerMockModule struct {
	name  string
	items []FileItem
}

func (m *scannerMockModule) Name() string                     { return m.name }
func (m *scannerMockModule) Description() string              { return "mock" }
func (m *scannerMockModule) Category() string                 { return "Recommended" }
func (m *scannerMockModule) Scan() ([]FileItem, error)        { return m.items, nil }
func (m *scannerMockModule) Delete([]FileItem) (int64, error) { return 0, nil }

func TestScanner_Scan(t *testing.T) {
	m1 := &scannerMockModule{name: "M1", items: []FileItem{{Path: "p1", Size: 10}}}
	m2 := &scannerMockModule{name: "M2", items: []FileItem{{Path: "p2", Size: 20}}}

	scanner := NewScanner()
	scanner.Register(m1)
	scanner.Register(m2)

	results, err := scanner.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	if len(results) != 2 {
		t.Fatalf("expected 2 module results, got %d", len(results))
	}

	totalItems := 0
	for _, res := range results {
		totalItems += len(res.Items)
	}

	if totalItems != 2 {
		t.Errorf("expected 2 total items, got %d", totalItems)
	}
}

func TestScanner_ScanSorting(t *testing.T) {
	items := []FileItem{
		{Path: "small", Size: 10},
		{Path: "large", Size: 100},
		{Path: "medium", Size: 50},
	}
	m := &scannerMockModule{name: "M1", items: items}

	scanner := NewScanner()
	scanner.Register(m)

	results, err := scanner.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	resItems := results[0].Items
	if len(resItems) != 3 {
		t.Fatalf("expected 3 items, got %d", len(resItems))
	}

	if resItems[0].Size != 100 || resItems[1].Size != 50 || resItems[2].Size != 10 {
		t.Errorf("items not sorted correctly: got sizes %d, %d, %d", resItems[0].Size, resItems[1].Size, resItems[2].Size)
	}
}
