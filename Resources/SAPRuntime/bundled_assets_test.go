package assets

import (
	"context"
	"crypto/sha256"
	"errors"
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
	makeAssets := func(t *testing.T) string {
		directory := t.TempDir()
		for _, spec := range requiredFiles {
			if err := os.WriteFile(filepath.Join(directory, spec.name), []byte(spec.name), 0400); err != nil {
				t.Fatal(err)
			}
		}
		return directory
	}
	t.Run("read-only valid resources", func(t *testing.T) {
		directory := makeAssets(t)
		bundle, err := LoadBundledDirectory(context.Background(), directory)
		if err != nil || string(bundle.CommerceKit) != "CommerceKit" {
			t.Fatalf("load bundled resources: %v", err)
		}
		entries, err := os.ReadDir(directory)
		if err != nil || len(entries) != len(requiredFiles) {
			t.Fatalf("resource directory was modified: %v", err)
		}
	})
	t.Run("missing file", func(t *testing.T) {
		directory := makeAssets(t)
		if err := os.Remove(filepath.Join(directory, "CoreFP")); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadBundledDirectory(context.Background(), directory); err == nil {
			t.Fatal("missing resources were accepted")
		}
	})
	t.Run("same-size corruption", func(t *testing.T) {
		directory := makeAssets(t)
		path := filepath.Join(directory, "CoreFP")
		if err := os.Chmod(path, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadBundledDirectory(context.Background(), directory); err == nil {
			t.Fatal("corrupt resources were accepted")
		}
	})
	t.Run("cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := LoadBundledDirectory(ctx, t.TempDir()); !errors.Is(err, context.Canceled) {
			t.Fatalf("expected cancellation, got %v", err)
		}
	})
}
