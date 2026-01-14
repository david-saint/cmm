package cmm

// FileItem represents a single file or directory that can be cleaned.
type FileItem struct {
	Path string
	Size int64
	Type string // e.g. "dir", "file", "cache", etc.
}

// Module is the interface that all cleanup modules must implement.
type Module interface {
	Name() string
	Description() string
	Category() string // Recommended, Harsh
	Available() bool  // Returns true if the module is applicable to the current system
	Scan() ([]FileItem, error)
	Delete([]FileItem) (int64, error) // Returns bytes freed
}
