package cmm

// FileItem represents a single file or directory that can be cleaned.
type FileItem struct {
	Path string
	Size int64
}

// Module is the interface that all cleanup modules must implement.
type Module interface {
	Name() string
	Description() string
	Category() string // Recommended, Harsh
	Scan() ([]FileItem, error)
	Delete([]FileItem) (int64, error) // Returns bytes freed
}
