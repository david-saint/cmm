package cmm

import "errors"

// ExecutionEngine handles the actual deletion of files.
type ExecutionEngine struct {
	DryRun bool
}

// NewExecutionEngine creates a new ExecutionEngine.
func NewExecutionEngine(dryRun bool) *ExecutionEngine {
	return &ExecutionEngine{
		DryRun: dryRun,
	}
}

// Outcome is the result of deleting one module's items.
type Outcome struct {
	Module Module
	Result DeleteResult
	Err    error
}

// TotalFreed adds up what the modules really freed.
func TotalFreed(outcomes []Outcome) int64 {
	var total int64
	for _, o := range outcomes {
		total += o.Result.Freed
	}
	return total
}

// Execute runs the deletion logic for the given results, one module after the other. A module that fails
// never stops the others: every module is tried, each outcome says what happened, and the errors are returned
// together. A dry run calls nothing and reports nothing.
func (e *ExecutionEngine) Execute(results []ModuleResult) ([]Outcome, error) {
	if e.DryRun {
		return nil, nil
	}

	outcomes := make([]Outcome, 0, len(results))
	var errs []error
	for _, res := range results {
		r, err := res.Module.Delete(res.Items)
		outcomes = append(outcomes, Outcome{Module: res.Module, Result: r, Err: err})
		if err != nil {
			errs = append(errs, err)
		}
	}
	return outcomes, errors.Join(errs...)
}
