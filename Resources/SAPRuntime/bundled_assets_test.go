package assets

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

type rejectNetwork struct{ t *testing.T }

func (r rejectNetwork) RoundTrip(*http.Request) (*http.Response, error) {
	r.t.Error("bundled resources must never access the network")
	return nil, errors.New("network disabled")
}

type bundledFixture struct {
	name string
	data string
	mode fs.FileMode
}

func TestBundledAssets(t *testing.T) {
	previousTransport, previousFiles := http.DefaultTransport, requiredFiles
	http.DefaultTransport = rejectNetwork{t}
	requiredFiles = append([]fileSpec(nil), requiredFiles...)
	t.Cleanup(func() { http.DefaultTransport, requiredFiles = previousTransport, previousFiles })
	// Synthetic bytes replace only test expectations; no Apple resources are needed.
	for i := range requiredFiles {
		data := []byte(requiredFiles[i].name)
		requiredFiles[i].size = len(data)
		requiredFiles[i].digest = sha256.Sum256(data)
	}
	fixtures := func() []bundledFixture {
		var entries []bundledFixture
		for _, spec := range requiredFiles {
			entries = append(entries, bundledFixture{spec.name, spec.name, 0400})
		}
		return entries
	}
	makeArchive := func(t *testing.T, entries []bundledFixture) string {
		var buffer bytes.Buffer
		writer := zip.NewWriter(&buffer)
		for _, entry := range entries {
			header := &zip.FileHeader{Name: entry.name, Method: zip.Deflate}
			header.SetMode(entry.mode)
			stream, err := writer.CreateHeader(header)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := stream.Write([]byte(entry.data)); err != nil {
				t.Fatal(err)
			}
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(t.TempDir(), "SAPAssets.zip")
		if err := os.WriteFile(path, buffer.Bytes(), 0400); err != nil {
			t.Fatal(err)
		}
		return path
	}
	t.Run("read-only archive without extraction", func(t *testing.T) {
		path := makeArchive(t, fixtures())
		before, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		bundle, err := LoadBundledArchive(context.Background(), path)
		if err != nil || string(bundle.CommerceKit) != "CommerceKit" || string(bundle.CoreFPICXS) != "CoreFP.icxs" {
			t.Fatalf("load bundled resources: %v", err)
		}
		after, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(before, after) {
			t.Fatal("archive was modified")
		}
		entries, err := os.ReadDir(filepath.Dir(path))
		if err != nil || len(entries) != 1 {
			t.Fatalf("archive was extracted to disk: %v", err)
		}
	})
	for _, name := range []string{"missing", "duplicate", "traversal", "symlink", "size", "hash"} {
		t.Run(name, func(t *testing.T) {
			entries := fixtures()
			switch name {
			case "missing":
				entries = entries[1:]
			case "duplicate":
				entries[0] = entries[1]
			case "traversal":
				entries[0].name = "../CommerceKit"
			case "symlink":
				entries[0].mode |= fs.ModeSymlink
			case "size":
				entries[0].data += "resigned"
			case "hash":
				entries[0].data = "XXXXXXXXXXX"
			}
			if _, err := LoadBundledArchive(context.Background(), makeArchive(t, entries)); err == nil {
				t.Fatal("invalid archive was accepted")
			}
		})
	}
	t.Run("missing archive", func(t *testing.T) {
		if _, err := LoadBundledArchive(context.Background(), filepath.Join(t.TempDir(), "missing.zip")); err == nil {
			t.Fatal("missing archive was accepted")
		}
	})
	t.Run("truncated archive", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "broken.zip")
		if err := os.WriteFile(path, []byte("PK\x03\x04"), 0400); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadBundledArchive(context.Background(), path); err == nil {
			t.Fatal("truncated archive was accepted")
		}
	})
	t.Run("cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := LoadBundledArchive(ctx, makeArchive(t, fixtures())); !errors.Is(err, context.Canceled) {
			t.Fatalf("expected cancellation, got %v", err)
		}
		reader := bundledContextReader{ctx: ctx, reader: bytes.NewReader([]byte("data"))}
		if _, err := reader.Read(make([]byte, 4)); !errors.Is(err, context.Canceled) {
			t.Fatal("decompression ignored cancellation")
		}
	})
}
