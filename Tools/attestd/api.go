package main

import (
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// apiError is the only error shape the API returns. Messages never contain
// header values, challenges, kbsync blobs or cookies.
type apiError struct {
	status  int
	code    string
	message string
}

func (e *apiError) Error() string {
	return e.code + ": " + e.message
}

func badRequest(message string) *apiError {
	return &apiError{status: http.StatusBadRequest, code: "invalid_request", message: message}
}

var errNotProvisioned = &apiError{
	status:  http.StatusConflict,
	code:    "not_provisioned",
	message: "this device has no Store provisioning yet",
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, err error) {
	var api *apiError
	if !errors.As(err, &api) {
		api = &apiError{status: http.StatusInternalServerError, code: "emulator_failed", message: err.Error()}
	}

	writeJSON(w, api.status, map[string]string{"code": api.code, "message": api.message})
}

// cookieJSON mirrors ApplePackage's Cookie type.
type cookieJSON struct {
	Name      string   `json:"name"`
	Value     string   `json:"value"`
	Path      string   `json:"path"`
	Domain    *string  `json:"domain,omitempty"`
	ExpiresAt *float64 `json:"expiresAt,omitempty"`
	HTTPOnly  bool     `json:"httpOnly"`
	Secure    bool     `json:"secure"`
}

func (c cookieJSON) httpCookie() *http.Cookie {
	cookie := &http.Cookie{
		Name:     c.Name,
		Value:    c.Value,
		Path:     c.Path,
		HttpOnly: c.HTTPOnly,
		Secure:   c.Secure,
	}

	if c.Domain != nil {
		cookie.Domain = *c.Domain
	}

	if c.ExpiresAt != nil {
		seconds := math.Floor(*c.ExpiresAt)
		cookie.Expires = time.Unix(int64(seconds), int64((*c.ExpiresAt-seconds)*float64(time.Second)))
	}

	return cookie
}

// unixSeconds keeps whole seconds exact; UnixNano as float64 would round.
func unixSeconds(t time.Time) float64 {
	return float64(t.Unix()) + float64(t.Nanosecond())/float64(time.Second)
}

func cookieFromHTTP(cookie *http.Cookie, now time.Time) cookieJSON {
	result := cookieJSON{
		Name:     cookie.Name,
		Value:    cookie.Value,
		Path:     cookie.Path,
		HTTPOnly: cookie.HttpOnly,
		Secure:   cookie.Secure,
	}

	if result.Path == "" {
		result.Path = "/"
	}

	if cookie.Domain != "" {
		domain := cookie.Domain
		result.Domain = &domain
	}

	switch {
	case cookie.MaxAge > 0:
		expires := unixSeconds(now.Add(time.Duration(cookie.MaxAge) * time.Second))
		result.ExpiresAt = &expires
	case cookie.MaxAge < 0:
		expires := float64(now.Unix() - 1)
		result.ExpiresAt = &expires
	case !cookie.Expires.IsZero():
		expires := unixSeconds(cookie.Expires)
		result.ExpiresAt = &expires
	}

	return result
}

// recordingJar forwards to a real jar and remembers every cookie the server
// set, with its attributes, so they can be returned to the caller's session.
type recordingJar struct {
	inner http.CookieJar

	mu       sync.Mutex
	received []*http.Cookie
}

func (j *recordingJar) SetCookies(u *url.URL, cookies []*http.Cookie) {
	j.mu.Lock()
	for _, cookie := range cookies {
		copied := *cookie
		if copied.Domain == "" {
			copied.Domain = u.Hostname()
		}

		j.received = append(j.received, &copied)
	}
	j.mu.Unlock()

	j.inner.SetCookies(u, cookies)
}

func (j *recordingJar) Cookies(u *url.URL) []*http.Cookie {
	return j.inner.Cookies(u)
}

func (j *recordingJar) receivedCookies() []*http.Cookie {
	j.mu.Lock()
	defer j.mu.Unlock()

	return append([]*http.Cookie(nil), j.received...)
}

// appleHTTPS accepts only https URLs on apple.com hosts without credentials.
func appleHTTPS(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Host == "" {
		return nil, badRequest("url must be an https Apple URL")
	}

	host := strings.ToLower(parsed.Hostname())
	if host != "apple.com" && !strings.HasSuffix(host, ".apple.com") {
		return nil, badRequest("url must be an https Apple URL")
	}

	if port := parsed.Port(); port != "" && port != "443" {
		return nil, badRequest("url must use the default https port")
	}

	return parsed, nil
}
