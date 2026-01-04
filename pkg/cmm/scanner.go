package cmm

import (
	"sort"
)

// ModuleResult contains the results of a single module scan.
type ModuleResult struct {
	Module Module
	Items  []FileItem
}

// Scanner orchestrates multiple modules to find removable files.
type Scanner struct {
	modules []Module
}

// NewScanner creates a new Scanner.
func NewScanner() *Scanner {
	return &Scanner{
		modules: []Module{},
	}
}

// Register adds a module to the scanner.
func (s *Scanner) Register(m Module) {
	s.modules = append(s.modules, m)
}

// Scan runs all registered modules and returns their results.
func (s *Scanner) Scan() ([]ModuleResult, error) {
	var results []ModuleResult
	for _, m := range s.modules {
		items, err := m.Scan()
		if err != nil {
			return nil, err
		}

		// Sort items by size descending
		sort.Slice(items, func(i, j int) bool {
			return items[i].Size > items[j].Size
		})

		results = append(results, ModuleResult{
			Module: m,
			Items:  items,
		})
	}
	return results, nil
}
