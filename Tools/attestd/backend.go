package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"strings"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
	"github.com/majd/ipatool/v2/internal/storeauth"
)

type provisionInput struct {
	hardwareID []byte
	challenge  string
	endpoint   string
	userAgent  string
	identity   http.Header
	cookies    []*http.Cookie
}

// backend is the attestation engine. The real one calls ipatool; tests use a fake.
type backend interface {
	Prepare(ctx context.Context) error
	MachineHeaders(ctx context.Context, state []byte) (http.Header, []byte, error)
	Provision(ctx context.Context, state []byte, input provisionInput) ([]byte, []*http.Cookie, error)
	StoreHeaders(ctx context.Context, state []byte, endpoint string, hardwareID []byte) (map[string]string, []byte, error)
	KBSync(ctx context.Context, hardwareID []byte, dsid uint64) ([]byte, error)
}

type ipatoolBackend struct{}

func (ipatoolBackend) Prepare(ctx context.Context) error {
	if _, err := assets.Load(ctx); err != nil {
		return &apiError{status: http.StatusServiceUnavailable, code: "assets_unavailable", message: err.Error()}
	}

	return nil
}

func (ipatoolBackend) MachineHeaders(ctx context.Context, state []byte) (http.Header, []byte, error) {
	return storeauth.AnisetteHeaders(ctx, storeauth.NewHTTPClient(nil), state)
}

func (ipatoolBackend) Provision(ctx context.Context, state []byte, input provisionInput) ([]byte, []*http.Cookie, error) {
	bundle, err := assets.Load(ctx)
	if err != nil {
		return nil, nil, &apiError{status: http.StatusServiceUnavailable, code: "assets_unavailable", message: err.Error()}
	}

	// ipatool's native login provisions with the reserved DSID ^1.
	kbsync, err := machine.GenerateKBSync(ctx, bundle, input.hardwareID, ^uint64(1))
	if err != nil {
		return nil, nil, fmt.Errorf("generate provisioning kbsync: %w", err)
	}

	if len(kbsync) == 0 {
		return nil, nil, errors.New("generated provisioning kbsync is empty")
	}

	inner, err := cookiejar.New(nil)
	if err != nil {
		return nil, nil, err
	}

	endpoint, err := appleHTTPS(input.endpoint)
	if err != nil {
		return nil, nil, err
	}

	if len(input.cookies) > 0 {
		inner.SetCookies(endpoint, input.cookies)
	}

	jar := &recordingJar{inner: inner}

	next, err := storeauth.ProvisionStoreAnisette(
		ctx, storeauth.NewHTTPClient(jar), state, input.challenge, input.endpoint, input.userAgent,
		base64.StdEncoding.EncodeToString(kbsync), input.hardwareID, input.identity,
	)
	if err != nil {
		return nil, nil, &apiError{status: http.StatusBadGateway, code: "upstream_failed", message: err.Error()}
	}

	return next, jar.receivedCookies(), nil
}

func (ipatoolBackend) StoreHeaders(ctx context.Context, state []byte, endpoint string, hardwareID []byte) (map[string]string, []byte, error) {
	headers, next, err := storeauth.StoreAMDHeaders(ctx, state, endpoint, hardwareID)
	if err != nil && strings.Contains(err.Error(), "not provisioned") {
		return nil, nil, errNotProvisioned
	}

	return headers, next, err
}

func (ipatoolBackend) KBSync(ctx context.Context, hardwareID []byte, dsid uint64) ([]byte, error) {
	bundle, err := assets.Load(ctx)
	if err != nil {
		return nil, &apiError{status: http.StatusServiceUnavailable, code: "assets_unavailable", message: err.Error()}
	}

	return machine.GenerateKBSync(ctx, bundle, hardwareID, dsid)
}
