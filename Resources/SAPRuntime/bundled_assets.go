package assets

import (
	"context"
	"fmt"
)

// LoadBundledDirectory only reads the selected app resources. It must not use
// Load's download fallback or write into the signed, read-only application bundle.
func LoadBundledDirectory(ctx context.Context, directory string) (Bundle, error) {
	if err := ctx.Err(); err != nil {
		return Bundle{}, err
	}
	bundle, err := readCache(directory)
	if err != nil {
		return Bundle{}, fmt.Errorf("invalid bundled Apple SAP resources: %w", err)
	}
	return bundle, ctx.Err()
}
