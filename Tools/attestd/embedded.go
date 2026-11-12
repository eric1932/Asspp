package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sync"
)

// embedded runs the service in-process, for an app that links this program as
// a library instead of talking to it over HTTP. It uses the same handlers and
// the same JSON bodies as the HTTP API, without a listener or a token.
type embedded struct {
	mu      sync.Mutex
	handler http.Handler
	cancels map[uint64]context.CancelFunc
}

var embeddedService embedded

// embeddedMethods maps a method name to its HTTP verb. A method is the HTTP
// path without the /v1/ prefix.
var embeddedMethods = map[string]string{
	"health":          http.MethodGet,
	"prepare":         http.MethodPost,
	"machine-headers": http.MethodPost,
	"provision":       http.MethodPost,
	"store-headers":   http.MethodPost,
	"kbsync":          http.MethodPost,
}

func (e *embedded) configure(stateDir string, backend backend) error {
	store, err := newStateStore(stateDir)
	if err != nil {
		return err
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	e.handler = newServer(store, "", backend).mux()
	if e.cancels == nil {
		e.cancels = make(map[uint64]context.CancelFunc)
	}

	return nil
}

// call runs one method and returns the status and JSON body the HTTP API would
// have sent. A non-zero cancelToken lets cancel stop the call from another
// goroutine; tokens are chosen by the caller and must be unique while in use.
func (e *embedded) call(method string, request []byte, cancelToken uint64) (int, []byte) {
	verb, known := embeddedMethods[method]
	if !known {
		return embeddedError(http.StatusNotFound, "invalid_request", "unknown method")
	}

	if len(request) > maxRequestBytes {
		return embeddedError(http.StatusBadRequest, "invalid_request", "request is too large")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	e.mu.Lock()
	handler := e.handler
	if handler != nil && cancelToken != 0 {
		e.cancels[cancelToken] = cancel
	}
	e.mu.Unlock()

	if handler == nil {
		return embeddedError(http.StatusServiceUnavailable, "not_configured", "call configure first")
	}

	if cancelToken != 0 {
		defer func() {
			e.mu.Lock()
			delete(e.cancels, cancelToken)
			e.mu.Unlock()
		}()
	}

	httpRequest, err := http.NewRequestWithContext(ctx, verb, "/v1/"+method, bytes.NewReader(request))
	if err != nil {
		return embeddedError(http.StatusBadRequest, "invalid_request", "could not build the request")
	}

	response := &memoryResponse{header: make(http.Header)}
	handler.ServeHTTP(response, httpRequest)

	if response.status == 0 {
		response.status = http.StatusOK
	}

	return response.status, response.body.Bytes()
}

// cancel stops the call that was started with the token. It is safe to call
// from any goroutine, more than once, and for a token that already finished.
func (e *embedded) cancel(cancelToken uint64) {
	e.mu.Lock()
	cancel := e.cancels[cancelToken]
	e.mu.Unlock()

	if cancel != nil {
		cancel()
	}
}

func embeddedError(status int, code, message string) (int, []byte) {
	body, _ := json.Marshal(map[string]string{"code": code, "message": message})

	return status, body
}

// memoryResponse collects a handler's response in memory.
type memoryResponse struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (m *memoryResponse) Header() http.Header { return m.header }

func (m *memoryResponse) WriteHeader(status int) {
	if m.status == 0 {
		m.status = status
	}
}

func (m *memoryResponse) Write(data []byte) (int, error) {
	if m.status == 0 {
		m.status = http.StatusOK
	}

	return m.body.Write(data)
}
