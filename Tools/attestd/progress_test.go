package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
)

func TestDefaultTransportStaysConcrete(t *testing.T) {
	// ipatool clones http.DefaultTransport as an *http.Transport.
	if _, ok := http.DefaultTransport.(*http.Transport); !ok {
		t.Fatalf("http.DefaultTransport is %T", http.DefaultTransport)
	}
}

func TestCountingDialerCountsOnlyTheAssetHost(t *testing.T) {
	for _, test := range []struct {
		address string
		counted bool
	}{
		{assetHost + ":443", true},
		{"UPDATES.CDN-APPLE.COM:443", true},
		{"auth.itunes.apple.com:443", false},
		{"not-an-address", false},
	} {
		var counter atomic.Int64

		dial := countingDialer(func(context.Context, string, string) (net.Conn, error) {
			client, server := net.Pipe()
			go func() {
				_, _ = server.Write(make([]byte, 1000))
				_ = server.Close()
			}()

			return client, nil
		}, &counter)

		conn, err := dial(context.Background(), "tcp", test.address)
		if err != nil {
			t.Fatalf("%s: dial: %v", test.address, err)
		}

		read, err := io.Copy(io.Discard, conn)
		_ = conn.Close()

		if err != nil || read != 1000 {
			t.Fatalf("%s: read %d bytes, %v", test.address, read, err)
		}

		want := int64(0)
		if test.counted {
			want = 1000
		}

		if got := counter.Load(); got != want {
			t.Errorf("%s: counted %d bytes, want %d", test.address, got, want)
		}
	}
}
