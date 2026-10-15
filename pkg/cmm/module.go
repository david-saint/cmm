package cmm

// FileItem represents a single file or directory that can be cleaned.
type FileItem struct {
	Path string
	Size int64
	Type string // e.g. "dir", "file", "cache", etc.
}

// DeleteResult is what a module's Delete really did, so no screen claims more than happened.
type DeleteResult struct {
	Freed   int64    // bytes actually freed
	Skipped int      // items left alone because they were no longer safe to delete (nothing was changed)
	Failed  int      // items that could not be deleted
	Notes   []string // why, one line per skipped or failed item
}

// Module is the interface that all cleanup modules must implement.
type Module interface {
	Name() string
	Description() string
	Category() string // Recommended, Harsh
	Scan() ([]FileItem, error)
	// Delete removes the items and says what happened to each. A non-nil error means the module could not do
	// its job at all; items that fail or are skipped are reported in the result instead.
	Delete([]FileItem) (DeleteResult, error)
}
