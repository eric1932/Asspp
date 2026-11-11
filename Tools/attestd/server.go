package main

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxRequestBytes = 1 << 20

type server struct {
	store   *stateStore
	token   string
	backend backend
	slot    chan struct{}
	now     func() time.Time
}

func newServer(store *stateStore, token string, backend backend) *server {
	return &server{store: store, token: token, backend: backend, slot: make(chan struct{}, 1), now: time.Now}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.health)
	mux.HandleFunc("POST /v1/prepare", s.serialized(s.prepare))
	mux.HandleFunc("POST /v1/machine-headers", s.serialized(s.machineHeaders))
	mux.HandleFunc("POST /v1/provision", s.serialized(s.provision))
	mux.HandleFunc("POST /v1/store-headers", s.serialized(s.storeHeaders))
	mux.HandleFunc("POST /v1/kbsync", s.serialized(s.kbsync))

	return s.authenticated(mux)
}

func (s *server) authenticated(next http.Handler) http.Handler {
	expected := []byte("Bearer " + s.token)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, expected) != 1 {
			writeError(w, &apiError{status: http.StatusUnauthorized, code: "unauthorized", message: "missing or wrong bearer token"})
			return
		}

		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// serialized runs one emulator operation at a time and logs its duration.
// Waiting for the slot honors the client's cancellation.
func (s *server) serialized(handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		select {
		case s.slot <- struct{}{}:
			defer func() { <-s.slot }()
		case <-r.Context().Done():
			writeError(w, &apiError{status: 499, code: "canceled", message: "request canceled while waiting"})
			return
		}

		start := s.now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		handler(recorder, r)
		log.Printf("%s -> %d in %s", r.URL.Path, recorder.status, s.now().Sub(start).Round(time.Millisecond))
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, value any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	if err := json.NewDecoder(r.Body).Decode(value); err != nil {
		return badRequest("invalid JSON body")
	}

	return nil
}

func flattenHeader(header http.Header) map[string]string {
	result := make(map[string]string, len(header))
	for key, values := range header {
		result[key] = strings.Join(values, ", ")
	}

	return result
}

func cacheHasEntries(parts ...string) bool {
	root, err := os.UserCacheDir()
	if err != nil {
		return false
	}

	entries, err := os.ReadDir(filepath.Join(append([]string{root}, parts...)...))

	return err == nil && len(entries) > 0
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"version":       version,
		"ipatoolCommit": ipatoolCommit,
		"assetsCached":  cacheHasEntries("ipatool", "sap"),
		"unicornCached": cacheHasEntries("ipatool", "unicorn"),
	})
}

func (s *server) prepare(w http.ResponseWriter, r *http.Request) {
	if err := s.backend.Prepare(r.Context()); err != nil {
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{})
}

func (s *server) machineHeaders(w http.ResponseWriter, r *http.Request) {
	var request struct {
		GUID string `json:"guid"`
	}

	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, err)
		return
	}

	guid, _, err := parseGUID(request.GUID)
	if err != nil {
		writeError(w, err)
		return
	}

	state, err := s.store.load(guid)
	if err != nil {
		writeError(w, err)
		return
	}

	headers, next, err := s.backend.MachineHeaders(r.Context(), state)
	if err != nil {
		writeError(w, err)
		return
	}

	if err := s.store.save(guid, next); err != nil {
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"headers": flattenHeader(headers)})
}

func (s *server) provision(w http.ResponseWriter, r *http.Request) {
	var request struct {
		GUID           string            `json:"guid"`
		Challenge      string            `json:"challenge"`
		Endpoint       string            `json:"endpoint"`
		UserAgent      string            `json:"userAgent"`
		MachineHeaders map[string]string `json:"machineHeaders"`
		Cookies        []cookieJSON      `json:"cookies"`
	}

	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, err)
		return
	}

	guid, hardwareID, err := parseGUID(request.GUID)
	if err != nil {
		writeError(w, err)
		return
	}

	switch {
	case strings.TrimSpace(request.Challenge) == "":
		writeError(w, badRequest("challenge is required"))
		return
	case strings.TrimSpace(request.UserAgent) == "":
		writeError(w, badRequest("userAgent is required"))
		return
	case len(request.MachineHeaders) == 0:
		writeError(w, badRequest("machineHeaders is required"))
		return
	}

	if _, err := appleHTTPS(request.Endpoint); err != nil {
		writeError(w, err)
		return
	}

	state, err := s.store.load(guid)
	if err != nil {
		writeError(w, err)
		return
	}

	if len(state) == 0 {
		writeError(w, &apiError{status: http.StatusConflict, code: "not_provisioned", message: "call machine-headers for this device first"})
		return
	}

	identity := make(http.Header, len(request.MachineHeaders))
	for key, value := range request.MachineHeaders {
		identity.Set(key, value)
	}

	cookies := make([]*http.Cookie, 0, len(request.Cookies))
	for _, cookie := range request.Cookies {
		cookies = append(cookies, cookie.httpCookie())
	}

	next, received, err := s.backend.Provision(r.Context(), state, provisionInput{
		hardwareID: hardwareID,
		challenge:  strings.TrimSpace(request.Challenge),
		endpoint:   request.Endpoint,
		userAgent:  request.UserAgent,
		identity:   identity,
		cookies:    cookies,
	})
	if err != nil {
		writeError(w, err)
		return
	}

	if err := s.store.save(guid, next); err != nil {
		writeError(w, err)
		return
	}

	now := s.now()
	result := make([]cookieJSON, 0, len(received))
	for _, cookie := range received {
		result = append(result, cookieFromHTTP(cookie, now))
	}

	writeJSON(w, http.StatusOK, map[string]any{"cookies": result})
}

func (s *server) storeHeaders(w http.ResponseWriter, r *http.Request) {
	var request struct {
		GUID string `json:"guid"`
		URL  string `json:"url"`
	}

	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, err)
		return
	}

	guid, hardwareID, err := parseGUID(request.GUID)
	if err != nil {
		writeError(w, err)
		return
	}

	if _, err := appleHTTPS(request.URL); err != nil {
		writeError(w, err)
		return
	}

	state, err := s.store.load(guid)
	if err != nil {
		writeError(w, err)
		return
	}

	if len(state) == 0 {
		writeError(w, errNotProvisioned)
		return
	}

	headers, next, err := s.backend.StoreHeaders(r.Context(), state, request.URL, hardwareID)
	if err != nil {
		writeError(w, err)
		return
	}

	if err := s.store.save(guid, next); err != nil {
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"headers": headers})
}

func (s *server) kbsync(w http.ResponseWriter, r *http.Request) {
	var request struct {
		GUID string `json:"guid"`
		DSID string `json:"dsid"`
	}

	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, err)
		return
	}

	_, hardwareID, err := parseGUID(request.GUID)
	if err != nil {
		writeError(w, err)
		return
	}

	dsid, err := strconv.ParseUint(strings.TrimSpace(request.DSID), 10, 64)
	if err != nil || dsid == 0 {
		writeError(w, badRequest("dsid must be a positive decimal integer string"))
		return
	}

	data, err := s.backend.KBSync(r.Context(), hardwareID, dsid)
	if err != nil {
		writeError(w, err)
		return
	}

	if len(data) == 0 {
		writeError(w, errors.New("generated kbsync is empty"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"kbsync": base64.StdEncoding.EncodeToString(data)})
}
