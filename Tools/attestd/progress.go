package main

import (
	"context"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
)

// assetHost serves the macOS restore image that the first prepare reads
// Apple's components from.
const assetHost = "updates.cdn-apple.com"

// assetBytesReceived counts the bytes read from assetHost since the process
// started. health reports it, so a client can show how far the first download
// has got.
var assetBytesReceived atomic.Int64

type dialFunc func(ctx context.Context, network, address string) (net.Conn, error)

// The count is taken where connections are dialed. http.DefaultTransport
// cannot be wrapped, because ipatool clones it as an *http.Transport.
func init() {
	transport, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return
	}

	dial := transport.DialContext
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}

	transport.DialContext = countingDialer(dial, &assetBytesReceived)
}

// countingDialer adds the bytes read from connections to assetHost to counter.
func countingDialer(dial dialFunc, counter *atomic.Int64) dialFunc {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := dial(ctx, network, address)
		if err != nil {
			return nil, err
		}

		host, _, splitErr := net.SplitHostPort(address)
		if splitErr != nil || !strings.EqualFold(host, assetHost) {
			return conn, nil
		}

		return &countingConn{Conn: conn, counter: counter}, nil
	}
}

type countingConn struct {
	net.Conn
	counter *atomic.Int64
}

func (c *countingConn) Read(data []byte) (int, error) {
	n, err := c.Conn.Read(data)
	c.counter.Add(int64(n))

	return n, err
}
