package assets

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
)

// Keep guest Mach-O files inside a data archive so recursive app re-signers do
// not rewrite their code signatures. Decompress only into memory, never the app
// bundle or download cache. A corrupt archive must not trigger a download.
func LoadBundledArchive(ctx context.Context, path string) (Bundle, error) {
	bundle, err := readBundledArchive(ctx, path)
	if err != nil {
		return Bundle{}, fmt.Errorf("invalid bundled Apple SAP resources: %w", err)
	}
	return bundle, nil
}

func readBundledArchive(ctx context.Context, path string) (Bundle, error) {
	if err := ctx.Err(); err != nil {
		return Bundle{}, err
	}
	file, err := os.Open(path)
	if err != nil {
		return Bundle{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Bundle{}, err
	}
	if !info.Mode().IsRegular() || info.Size() > 64<<20 {
		return Bundle{}, errors.New("invalid SAP archive size or file type")
	}
	archive, err := zip.NewReader(file, info.Size())
	if err != nil {
		return Bundle{}, err
	}
	if len(archive.File) != len(requiredFiles) {
		return Bundle{}, errors.New("SAP archive must contain exactly the required files")
	}
	wanted := make(map[string]fileSpec, len(requiredFiles))
	for _, spec := range requiredFiles {
		wanted[spec.name] = spec
	}
	files := make(map[string][]byte, len(requiredFiles))
	for _, entry := range archive.File {
		spec, ok := wanted[entry.Name]
		if !ok || files[entry.Name] != nil || !entry.Mode().IsRegular() {
			return Bundle{}, errors.New("unexpected or duplicate SAP archive entry")
		}
		if entry.UncompressedSize64 != uint64(spec.size) {
			return Bundle{}, fmt.Errorf("incorrect bundled asset size: %s", entry.Name)
		}
		data, err := readBundledEntry(ctx, entry, spec.size)
		if err != nil {
			return Bundle{}, fmt.Errorf("read %s: %w", entry.Name, err)
		}
		files[entry.Name] = data
	}
	bundle := bundleFrom(files)
	if err := validate(bundle); err != nil {
		return Bundle{}, err
	}
	return bundle, ctx.Err()
}

func readBundledEntry(ctx context.Context, entry *zip.File, size int) ([]byte, error) {
	stream, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer stream.Close()
	reader := bundledContextReader{ctx: ctx, reader: stream}
	data := make([]byte, size)
	if _, err := io.ReadFull(reader, data); err != nil {
		return nil, err
	}
	// Read through EOF to verify the ZIP checksum and reject extra bytes, while
	// bounding memory by the pinned size even if archive metadata is malformed.
	var extra [1]byte
	if count, err := io.ReadFull(reader, extra[:]); count != 0 {
		return nil, errors.New("asset exceeds its pinned size")
	} else if !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("verify asset ZIP checksum: %w", err)
	}
	return data, nil
}

type bundledContextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r bundledContextReader) Read(data []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(data)
}
