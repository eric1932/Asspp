package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func decodeEmbedded(t *testing.T, body []byte) map[string]any {
	t.Helper()

	decoded := map[string]any{}
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}

	return decoded
}

func TestEmbeddedCallNeedsConfigure(t *testing.T) {
	var service embedded

	status, body := service.call("health", nil, 0)
	if status != http.StatusServiceUnavailable || decodeEmbedded(t, body)["code"] != "not_configured" {
		t.Fatalf("%d %s", status, body)
	}
}

func TestEmbeddedCallUsesTheHTTPHandlersWithoutAToken(t *testing.T) {
	var service embedded
	if err := service.configure(t.TempDir(), &fakeBackend{}); err != nil {
		t.Fatal(err)
	}

	status, body := service.call("health", nil, 0)
	if status != http.StatusOK || decodeEmbedded(t, body)["version"] != version {
		t.Fatalf("health: %d %s", status, body)
	}

	status, body = service.call("kbsync", []byte(`{"guid":"A1B2C3D4E5F6","dsid":"42"}`), 0)
	if status != http.StatusOK || decodeEmbedded(t, body)["kbsync"] != "AQID" {
		t.Fatalf("kbsync: %d %s", status, body)
	}

	status, body = service.call("store-headers", []byte(`{"guid":"A1B2C3D4E5F6","url":"https://buy.itunes.apple.com/x"}`), 0)
	if status != http.StatusConflict || decodeEmbedded(t, body)["code"] != "not_provisioned" {
		t.Fatalf("store-headers: %d %s", status, body)
	}
}

func TestEmbeddedCallRejectsUnknownMethodsAndLargeRequests(t *testing.T) {
	var service embedded
	if err := service.configure(t.TempDir(), &fakeBackend{}); err != nil {
		t.Fatal(err)
	}

	for _, method := range []string{"", "nope", "../v1/kbsync", "/v1/kbsync"} {
		status, body := service.call(method, nil, 0)
		if status != http.StatusNotFound || decodeEmbedded(t, body)["code"] != "invalid_request" {
			t.Errorf("method %q: %d %s", method, status, body)
		}
	}

	status, _ := service.call("kbsync", make([]byte, maxRequestBytes+1), 0)
	if status != http.StatusBadRequest {
		t.Fatalf("large request: %d", status)
	}
}

type blockingBackend struct {
	fakeBackend
	started chan struct{}
}

func (b *blockingBackend) KBSync(ctx context.Context, _ []byte, _ uint64) ([]byte, error) {
	close(b.started)
	<-ctx.Done()

	return nil, &apiError{status: 499, code: "canceled", message: "canceled"}
}

func TestEmbeddedCancelStopsARunningCall(t *testing.T) {
	var service embedded

	backend := &blockingBackend{started: make(chan struct{})}
	if err := service.configure(t.TempDir(), backend); err != nil {
		t.Fatal(err)
	}

	finished := make(chan int, 1)
	go func() {
		status, _ := service.call("kbsync", []byte(`{"guid":"A1B2C3D4E5F6","dsid":"42"}`), 7)
		finished <- status
	}()

	<-backend.started
	service.cancel(7)

	select {
	case status := <-finished:
		if status != 499 {
			t.Fatalf("status %d", status)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("call did not stop")
	}

	// Cancelling again, or a token that never existed, is a no-op.
	service.cancel(7)
	service.cancel(99)
}
