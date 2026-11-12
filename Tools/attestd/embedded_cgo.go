//go:build asspp_embedded

package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"log"
	"net/http"
	"unsafe"
)

// The C interface of the embedded runtime, declared in embedded/AssppAttest.h.
// Inputs are borrowed for the duration of a call and copied at once. Outputs
// are allocated on the C heap and released with asb_free. No Go pointer crosses
// the boundary.

//export asb_configure
func asb_configure(stateDir *C.char) C.int32_t {
	if stateDir == nil {
		return 1
	}

	if err := embeddedService.configure(C.GoString(stateDir), ipatoolBackend{}); err != nil {
		log.Printf("embedded runtime: state directory: %v", err)
		return 1
	}

	return 0
}

//export asb_call
func asb_call(method *C.char, request *C.uint8_t, requestLength C.uint64_t, cancelToken C.uint64_t, response **C.uint8_t, responseLength *C.uint64_t) C.int32_t {
	if method == nil || response == nil || responseLength == nil {
		return http.StatusBadRequest
	}

	var status int
	var payload []byte

	switch {
	case requestLength > maxRequestBytes:
		status, payload = embeddedError(http.StatusBadRequest, "invalid_request", "request is too large")
	case request == nil || requestLength == 0:
		status, payload = embeddedService.call(C.GoString(method), nil, uint64(cancelToken))
	default:
		body := C.GoBytes(unsafe.Pointer(request), C.int(requestLength))
		status, payload = embeddedService.call(C.GoString(method), body, uint64(cancelToken))
	}

	*response = (*C.uint8_t)(C.CBytes(payload))
	*responseLength = C.uint64_t(len(payload))

	if status == http.StatusOK {
		return 0
	}

	return C.int32_t(status)
}

//export asb_cancel
func asb_cancel(cancelToken C.uint64_t) {
	embeddedService.cancel(uint64(cancelToken))
}

//export asb_free
func asb_free(pointer unsafe.Pointer) {
	C.free(pointer)
}
