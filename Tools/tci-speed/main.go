// Command tci-speed times ipatool's emulated kbsync generation.
//
// It is a measurement probe, not part of Asspp or asspp-attestd. It is built
// inside the pinned ipatool source tree (Tools/attestd/IPATOOL_COMMIT) with a
// loader patch that lets ASSPP_UNICORN_LIBRARY point at another libunicorn, so
// the same workload can run on the stock JIT build and on an interpreter-only
// build. kbsync needs no Apple account and no network after the public Apple
// components are cached; the hardware ID and DSID below are made up.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

const (
	runs       = 3
	runTimeout = 40 * time.Minute
	fakeDSID   = 12345678901
)

func main() {
	engine := "stock-jit"
	if os.Getenv("ASSPP_UNICORN_LIBRARY") != "" {
		engine = "interpreter"
	}

	start := time.Now()
	bundle, err := assets.Load(context.Background())
	if err != nil {
		fmt.Fprintln(os.Stderr, "load Apple components:", err)
		os.Exit(1)
	}
	fmt.Printf("engine=%s assets_load_seconds=%.1f\n", engine, time.Since(start).Seconds())

	hardwareID := []byte{0x02, 0x00, 0x5E, 0x10, 0x20, 0x30}
	for run := 1; run <= runs; run++ {
		ctx, cancel := context.WithTimeout(context.Background(), runTimeout)
		start := time.Now()
		output, err := machine.GenerateKBSync(ctx, bundle, hardwareID, fakeDSID)
		elapsed := time.Since(start).Seconds()
		cancel()
		if err != nil {
			fmt.Printf("engine=%s run=%d kbsync_seconds=%.1f error=%v\n", engine, run, elapsed, err)
			os.Exit(1)
		}
		fmt.Printf("engine=%s run=%d kbsync_seconds=%.2f kbsync_bytes=%d\n", engine, run, elapsed, len(output))
	}
}
