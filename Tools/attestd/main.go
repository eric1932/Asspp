// Command asspp-attestd serves Apple Store device attestation (anisette, Store
// provisioning, Store AMD proof and kbsync) over a small authenticated HTTP API.
//
// It is built inside a pinned ipatool source tree (see IPATOOL_COMMIT) so it can
// reuse ipatool's internal packages. Apple's components and libunicorn are
// downloaded at runtime into ipatool's cache directory; nothing from Apple or
// Unicorn is embedded in this program or in Asspp.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

var (
	version       = "dev"
	ipatoolCommit = "unknown"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: asspp-attestd serve [--listen 127.0.0.1:18765] [--state-dir DIR]")
		os.Exit(2)
	}

	flags := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := flags.String("listen", "127.0.0.1:18765", "address to listen on")
	stateDir := flags.String("state-dir", defaultStateDir(), "directory for per-device state and the API token")
	_ = flags.Parse(os.Args[2:])

	store, err := newStateStore(*stateDir)
	if err != nil {
		log.Fatalf("state directory: %v", err)
	}

	token, created, err := loadOrCreateToken(*stateDir)
	if err != nil {
		log.Fatalf("API token: %v", err)
	}

	if created {
		log.Printf("generated API token, saved in %s: %s", filepath.Join(*stateDir, tokenFileName), token)
	} else {
		log.Printf("API token is in %s", filepath.Join(*stateDir, tokenFileName))
	}

	srv := newServer(store, token, ipatoolBackend{})
	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()

		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("asspp-attestd %s (ipatool %s) listening on %s, state in %s", version, ipatoolCommit, *listen, *stateDir)

	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func defaultStateDir() string {
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "asspp-attestd")
	}

	return "asspp-attestd-state"
}
