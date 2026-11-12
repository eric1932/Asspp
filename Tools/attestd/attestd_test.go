package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type fakeBackend struct {
	machineState []byte
	storeErr     error
	provisioned  []byte
	setCookies   []*http.Cookie

	lastProvision provisionInput
	lastStoreURL  string
	lastState     []byte
}

func (f *fakeBackend) Prepare(context.Context) error { return nil }

func (f *fakeBackend) MachineHeaders(_ context.Context, state []byte) (http.Header, []byte, error) {
	f.lastState = state
	header := http.Header{}
	header.Set("X-Apple-I-MD", "otp")
	header.Set("X-Apple-I-MD-M", "mid")

	return header, f.machineState, nil
}

func (f *fakeBackend) Provision(_ context.Context, state []byte, input provisionInput) ([]byte, []*http.Cookie, error) {
	f.lastState = state
	f.lastProvision = input

	return f.provisioned, f.setCookies, nil
}

func (f *fakeBackend) StoreHeaders(_ context.Context, state []byte, endpoint string, _ []byte) (map[string]string, []byte, error) {
	f.lastState = state
	f.lastStoreURL = endpoint
	if f.storeErr != nil {
		return nil, nil, f.storeErr
	}

	return map[string]string{"X-Apple-AMD": "proof", "X-Apple-AMD-M": "machine"}, []byte(`{"next":true}`), nil
}

func (f *fakeBackend) KBSync(context.Context, []byte, uint64) ([]byte, error) {
	return []byte{1, 2, 3}, nil
}

const testToken = "0123456789abcdef0123456789abcdef"

func newTestServer(t *testing.T, fake *fakeBackend) (*server, *stateStore) {
	t.Helper()

	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	srv := newServer(store, testToken, fake)
	srv.now = func() time.Time { return time.Unix(1_800_000_000, 0) }

	return srv, store
}

func call(t *testing.T, srv *server, method, path string, body any, token string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()

	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}

		reader = bytes.NewReader(data)
	}

	request := httptest.NewRequest(method, path, reader)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}

	recorder := httptest.NewRecorder()
	srv.routes().ServeHTTP(recorder, request)

	decoded := map[string]any{}
	_ = json.Unmarshal(recorder.Body.Bytes(), &decoded)

	return recorder, decoded
}

func TestParseGUID(t *testing.T) {
	guid, hardwareID, err := parseGUID(" a1b2c3d4e5f6 ")
	if err != nil || guid != "A1B2C3D4E5F6" || len(hardwareID) != 6 || hardwareID[0] != 0xA1 {
		t.Fatalf("got %q %x %v", guid, hardwareID, err)
	}

	for _, bad := range []string{"", "A1B2C3D4E5", "A1B2C3D4E5F6A7", "A1:B2:C3:D4:E5", "ZZZZZZZZZZZZ"} {
		if _, _, err := parseGUID(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestStateStoreRoundTripAndPermissions(t *testing.T) {
	store, err := newStateStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	if data, err := store.load("A1B2C3D4E5F6"); err != nil || data != nil {
		t.Fatalf("missing state: %q %v", data, err)
	}

	for _, value := range []string{"first", "second"} {
		if err := store.save("A1B2C3D4E5F6", []byte(value)); err != nil {
			t.Fatal(err)
		}
	}

	data, err := store.load("A1B2C3D4E5F6")
	if err != nil || string(data) != "second" {
		t.Fatalf("got %q %v", data, err)
	}

	info, err := os.Stat(store.path("A1B2C3D4E5F6"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", info.Mode(), err)
	}

	entries, _ := os.ReadDir(store.dir)
	if len(entries) != 1 {
		t.Fatalf("leftover temporary files: %d entries", len(entries))
	}
}

func TestTokenIsCreatedOnceAndReused(t *testing.T) {
	dir := t.TempDir()

	first, created, err := loadOrCreateToken(dir)
	if err != nil || !created || len(first) != 64 {
		t.Fatalf("first %q %v %v", first, created, err)
	}

	second, created, err := loadOrCreateToken(dir)
	if err != nil || created || second != first {
		t.Fatalf("second %q %v %v", second, created, err)
	}

	info, err := os.Stat(filepath.Join(dir, tokenFileName))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("token mode %v %v", info.Mode(), err)
	}
}

func TestRequestsRequireToken(t *testing.T) {
	srv, _ := newTestServer(t, &fakeBackend{})

	for _, token := range []string{"", "wrong"} {
		recorder, body := call(t, srv, http.MethodGet, "/v1/health", nil, token)
		if recorder.Code != http.StatusUnauthorized || body["code"] != "unauthorized" {
			t.Fatalf("token %q: %d %v", token, recorder.Code, body)
		}
	}

	recorder, body := call(t, srv, http.MethodGet, "/v1/health", nil, testToken)
	if recorder.Code != http.StatusOK || body["ipatoolCommit"] == nil || body["assetBytes"] == nil {
		t.Fatalf("health: %d %v", recorder.Code, body)
	}
}

func TestStoreHeadersWithoutStateIsNotProvisioned(t *testing.T) {
	fake := &fakeBackend{}
	srv, _ := newTestServer(t, fake)

	recorder, body := call(t, srv, http.MethodPost, "/v1/store-headers",
		map[string]string{"guid": "A1B2C3D4E5F6", "url": "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/"}, testToken)
	if recorder.Code != http.StatusConflict || body["code"] != "not_provisioned" {
		t.Fatalf("%d %v", recorder.Code, body)
	}

	if fake.lastStoreURL != "" {
		t.Fatal("backend called without state")
	}
}

func TestStoreHeadersMapsBackendNotProvisioned(t *testing.T) {
	fake := &fakeBackend{storeErr: errNotProvisioned}
	srv, store := newTestServer(t, fake)
	if err := store.save("A1B2C3D4E5F6", []byte(`{"machine":true}`)); err != nil {
		t.Fatal(err)
	}

	recorder, body := call(t, srv, http.MethodPost, "/v1/store-headers",
		map[string]string{"guid": "a1b2c3d4e5f6", "url": "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/"}, testToken)
	if recorder.Code != http.StatusConflict || body["code"] != "not_provisioned" {
		t.Fatalf("%d %v", recorder.Code, body)
	}
}

func TestStoreHeadersPersistsNextState(t *testing.T) {
	fake := &fakeBackend{}
	srv, store := newTestServer(t, fake)
	if err := store.save("A1B2C3D4E5F6", []byte(`{"provisioned":true}`)); err != nil {
		t.Fatal(err)
	}

	endpoint := "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/"
	recorder, body := call(t, srv, http.MethodPost, "/v1/store-headers", map[string]string{"guid": "A1B2C3D4E5F6", "url": endpoint}, testToken)
	if recorder.Code != http.StatusOK {
		t.Fatalf("%d %v", recorder.Code, body)
	}

	headers, _ := body["headers"].(map[string]any)
	if headers["X-Apple-AMD"] != "proof" || fake.lastStoreURL != endpoint || string(fake.lastState) != `{"provisioned":true}` {
		t.Fatalf("headers %v url %q state %q", headers, fake.lastStoreURL, fake.lastState)
	}

	saved, _ := store.load("A1B2C3D4E5F6")
	if string(saved) != `{"next":true}` {
		t.Fatalf("saved %q", saved)
	}
}

func TestStoreHeadersRejectsNonAppleURLs(t *testing.T) {
	srv, store := newTestServer(t, &fakeBackend{})
	_ = store.save("A1B2C3D4E5F6", []byte("x"))

	for _, bad := range []string{"http://buy.itunes.apple.com/", "https://evil.example/", "https://user:pw@buy.itunes.apple.com/", "https://buy.itunes.apple.com:8443/", "https://apple.com.evil.example/"} {
		recorder, body := call(t, srv, http.MethodPost, "/v1/store-headers", map[string]string{"guid": "A1B2C3D4E5F6", "url": bad}, testToken)
		if recorder.Code != http.StatusBadRequest || body["code"] != "invalid_request" {
			t.Errorf("%s: %d %v", bad, recorder.Code, body)
		}
	}
}

func TestMachineHeadersPersistsState(t *testing.T) {
	fake := &fakeBackend{machineState: []byte(`{"identifier":"x"}`)}
	srv, store := newTestServer(t, fake)

	recorder, body := call(t, srv, http.MethodPost, "/v1/machine-headers", map[string]string{"guid": "A1B2C3D4E5F6"}, testToken)
	if recorder.Code != http.StatusOK {
		t.Fatalf("%d %v", recorder.Code, body)
	}

	headers, _ := body["headers"].(map[string]any)
	if headers["X-Apple-I-Md"] != "otp" {
		t.Fatalf("headers %v", headers)
	}

	saved, _ := store.load("A1B2C3D4E5F6")
	if string(saved) != `{"identifier":"x"}` {
		t.Fatalf("saved %q", saved)
	}
}

func TestProvisionRequiresMachineStateAndReturnsCookies(t *testing.T) {
	expires := time.Unix(1_900_000_000, 0)
	fake := &fakeBackend{
		provisioned: []byte(`{"provisioned":true}`),
		setCookies: []*http.Cookie{
			{Name: "itspod", Value: "9", Domain: ".apple.com", Path: "/", Expires: expires, Secure: true},
			{Name: "session", Value: "abc", Domain: "auth.itunes.apple.com", MaxAge: 60},
		},
	}
	srv, store := newTestServer(t, fake)

	request := map[string]any{
		"guid":           "A1B2C3D4E5F6",
		"challenge":      "c3BpbQ==",
		"endpoint":       "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish",
		"userAgent":      "Configurator/2.21",
		"machineHeaders": map[string]string{"X-Apple-I-MD": "otp", "X-Mme-Device-Id": "device"},
		"cookies":        []map[string]any{{"name": "mz_at0", "value": "v", "path": "/", "domain": ".apple.com", "httpOnly": true, "secure": true}},
	}

	recorder, body := call(t, srv, http.MethodPost, "/v1/provision", request, testToken)
	if recorder.Code != http.StatusConflict {
		t.Fatalf("without machine state: %d %v", recorder.Code, body)
	}

	_ = store.save("A1B2C3D4E5F6", []byte(`{"machine":true}`))

	recorder, body = call(t, srv, http.MethodPost, "/v1/provision", request, testToken)
	if recorder.Code != http.StatusOK {
		t.Fatalf("%d %v", recorder.Code, body)
	}

	if fake.lastProvision.challenge != "c3BpbQ==" || fake.lastProvision.identity.Get("X-Apple-I-MD") != "otp" ||
		len(fake.lastProvision.cookies) != 1 || len(fake.lastProvision.hardwareID) != 6 {
		t.Fatalf("input %+v", fake.lastProvision)
	}

	cookies, _ := body["cookies"].([]any)
	if len(cookies) != 2 {
		t.Fatalf("cookies %v", body)
	}

	first, _ := cookies[0].(map[string]any)
	if first["name"] != "itspod" || first["domain"] != ".apple.com" || first["expiresAt"] != float64(1_900_000_000) {
		t.Fatalf("first cookie %v", first)
	}

	second, _ := cookies[1].(map[string]any)
	if second["expiresAt"] != float64(1_800_000_060) || second["path"] != "/" {
		t.Fatalf("second cookie %v", second)
	}

	saved, _ := store.load("A1B2C3D4E5F6")
	if string(saved) != `{"provisioned":true}` {
		t.Fatalf("saved %q", saved)
	}
}

func TestKBSyncValidatesDSID(t *testing.T) {
	srv, _ := newTestServer(t, &fakeBackend{})

	for _, bad := range []string{"", "0", "-1", "abc"} {
		recorder, _ := call(t, srv, http.MethodPost, "/v1/kbsync", map[string]string{"guid": "A1B2C3D4E5F6", "dsid": bad}, testToken)
		if recorder.Code != http.StatusBadRequest {
			t.Errorf("dsid %q: %d", bad, recorder.Code)
		}
	}

	recorder, body := call(t, srv, http.MethodPost, "/v1/kbsync", map[string]string{"guid": "A1B2C3D4E5F6", "dsid": "18446744073709551614"}, testToken)
	if recorder.Code != http.StatusOK || body["kbsync"] != "AQID" {
		t.Fatalf("%d %v", recorder.Code, body)
	}
}

func TestRecordingJarKeepsAttributesAndForwards(t *testing.T) {
	inner, _ := cookiejar.New(nil)
	jar := &recordingJar{inner: inner}
	target, _ := url.Parse("https://auth.itunes.apple.com/auth/v1/otp/1.5/finish")

	jar.SetCookies(target, []*http.Cookie{{Name: "a", Value: "1", Path: "/"}})

	received := jar.receivedCookies()
	if len(received) != 1 || received[0].Domain != "auth.itunes.apple.com" {
		t.Fatalf("received %+v", received)
	}

	if cookies := jar.Cookies(target); len(cookies) != 1 || cookies[0].Value != "1" {
		t.Fatalf("forwarded %+v", cookies)
	}
}
