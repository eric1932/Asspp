package sap

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"howett.net/plist"
)

const probeUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

// This probe never reads credentials from environment, Keychain, or account files.
// Opt-in is mandatory even when called directly with go test.
func TestAssppSignedAuthentication(t *testing.T) {
	if os.Getenv("ASSPP_SAP_LIVE_PROBE") != "1" {
		t.Skip("real Apple SAP requests require ASSPP_SAP_LIVE_PROBE=1")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	hardware := make([]byte, 6)
	if _, err := rand.Read(hardware); err != nil {
		t.Fatal(err)
	}
	hardware[0] = (hardware[0] | 2) & 0xfe
	guid := strings.ToUpper(hex.EncodeToString(hardware))
	client := &http.Client{
		Timeout:       30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	fetch := func(endpoint string) []byte {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("User-Agent", probeUserAgent)
		request.Header.Set("Accept", "application/xml")
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != 200 {
			t.Fatalf("bag HTTP %d", response.StatusCode)
		}
		return data
	}
	data := fetch("https://init.itunes.apple.com/bag.xml?guid=" + guid)
	if start, end := bytes.Index(data, []byte("<plist")), bytes.Index(data, []byte("</plist>")); start >= 0 && end > start {
		data = data[start : end+len("</plist>")]
	}
	var bag map[string]any
	if _, err := plist.Unmarshal(data, &bag); err != nil {
		t.Fatal(err)
	}
	nested, _ := bag["urlBag"].(map[string]any)
	value := func(key string) string {
		if v, ok := bag[key]; ok {
			return fmt.Sprint(v)
		}
		if v, ok := nested[key]; ok {
			return fmt.Sprint(v)
		}
		t.Fatalf("bag is missing %s", key)
		return ""
	}
	if value("sign-sap-version") != "200" {
		t.Fatal("unsupported live SAP version")
	}
	endpoint := value("authenticateAccount")
	validate := func(raw string, allowed func(*url.URL) bool) {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || !allowed(u) {
			t.Fatal("unexpected Apple endpoint; refusing to send probe data")
		}
	}
	validate(endpoint, func(u *url.URL) bool {
		return u.Host == "buy.itunes.apple.com" && u.Path == "/WebObjects/MZFinance.woa/wa/authenticate"
	})
	setup, certificate := value("sign-sap-setup"), value("sign-sap-setup-cert")
	validate(setup, func(u *url.URL) bool { return u.Host == "fpinit.itunes.apple.com" })
	validate(certificate, func(u *url.URL) bool { return u.Host == "s.mzstatic.com" })
	signer, err := NewSigner(ctx, Config{SetupURL: setup, CertificateURL: certificate, Version: 200, HardwareID: hardware})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := signer.Close(); err != nil {
			t.Error(err)
		}
	}()

	body, err := plist.Marshal(map[string]string{
		"appleId": "asspp-sap-probe@example.invalid", "password": "not-a-real-apple-password",
		"attempt": "4", "guid": guid, "rmp": "0", "why": "signIn",
	}, plist.XMLFormat)
	if err != nil {
		t.Fatal(err)
	}
	signature, err := signer.Sign(body)
	if err != nil {
		t.Fatal(err)
	}
	if len(signature) == 0 {
		t.Fatal("empty signature")
	}

	send := func(signed bool) (int, []byte) {
		u, _ := url.Parse(endpoint)
		query := u.Query()
		query.Set("guid", guid)
		u.RawQuery = query.Encode()
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("User-Agent", probeUserAgent)
		request.Header.Set("Content-Type", "application/x-apple-plist")
		if signed {
			request.Header.Set("X-Apple-ActionSignature", base64.StdEncoding.EncodeToString(signature))
		}
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		output, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if err != nil {
			t.Fatal(err)
		}
		return response.StatusCode, output
	}
	unsignedStatus, unsignedBody := send(false)
	signedStatus, signedBody := send(true)
	t.Logf("unsigned HTTP %d (%d bytes); signed HTTP %d (%d bytes)", unsignedStatus, len(unsignedBody), signedStatus, len(signedBody))
	if unsignedStatus != 403 || len(unsignedBody) != 0 {
		t.Fatal("unsigned control changed; review Apple gateway behavior before accepting the probe")
	}
	if signedStatus != 200 {
		t.Fatalf("signed request HTTP %d; signature acceptance was not established", signedStatus)
	}
	var result map[string]any
	if _, err := plist.Unmarshal(signedBody, &result); err != nil {
		t.Fatal("signed response was not a plist")
	}
	if result["customerMessage"] != "MZFinance.BadLogin.Configurator_message" {
		t.Fatal("signed response did not reach the expected credential check")
	}
}
