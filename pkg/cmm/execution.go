package cmm

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

// Execute runs the deletion logic for the given results.
func (e *ExecutionEngine) Execute(results []ModuleResult) (int64, error) {
	if e.DryRun {
		return 0, nil
	}

	var totalFreed int64
	for _, res := range results {
		freed, err := res.Module.Delete(res.Items)
		if err != nil {
			return totalFreed, err
		}
		totalFreed += freed
	}
	return totalFreed, nil
}
