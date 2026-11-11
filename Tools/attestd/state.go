package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const tokenFileName = "token"

var guidPattern = regexp.MustCompile(`^[0-9A-Fa-f]{12}$`)

// parseGUID validates Asspp's 12-hex-digit device identifier and returns the
// normalized identifier and the 6-byte hardware ID ipatool expects.
func parseGUID(raw string) (string, []byte, error) {
	guid := strings.TrimSpace(raw)
	if !guidPattern.MatchString(guid) {
		return "", nil, badRequest("guid must be exactly 12 hexadecimal characters")
	}

	guid = strings.ToUpper(guid)

	hardwareID, err := hex.DecodeString(guid)
	if err != nil || len(hardwareID) != 6 {
		return "", nil, badRequest("guid must decode to 6 bytes")
	}

	return guid, hardwareID, nil
}

// stateStore keeps ipatool's opaque anisette state, one file per device GUID.
// Callers serialize access; the store itself only guarantees atomic replacement.
type stateStore struct {
	dir string
}

func newStateStore(dir string) (*stateStore, error) {
	if dir == "" {
		return nil, errors.New("empty state directory")
	}

	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}

	return &stateStore{dir: dir}, nil
}

func (s *stateStore) path(guid string) string {
	return filepath.Join(s.dir, guid+".json")
}

// load returns nil (not an error) when the device has no state yet.
func (s *stateStore) load(guid string) ([]byte, error) {
	data, err := os.ReadFile(s.path(guid))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}

	return data, err
}

func (s *stateStore) save(guid string, data []byte) error {
	if len(data) == 0 {
		return nil
	}

	return writeFileAtomic(s.path(guid), data)
}

func writeFileAtomic(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}

	name := temporary.Name()
	defer os.Remove(name)

	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}

	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}

	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}

	if err := temporary.Close(); err != nil {
		return err
	}

	return os.Rename(name, path)
}

func loadOrCreateToken(dir string) (string, bool, error) {
	path := filepath.Join(dir, tokenFileName)

	data, err := os.ReadFile(path)
	if err == nil {
		token := strings.TrimSpace(string(data))
		if len(token) >= 32 {
			return token, false, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", false, err
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", false, fmt.Errorf("generate token: %w", err)
	}

	token := hex.EncodeToString(raw)
	if err := writeFileAtomic(path, []byte(token+"\n")); err != nil {
		return "", false, err
	}

	return token, true, nil
}
