// AssppAttest: asspp-attestd as an in-process library.
//
// The same methods and JSON bodies as the HTTP API (see ../README.md), without
// a listener or a token. All functions are thread-safe. asb_call blocks, for
// seconds, or minutes the first time while Apple's components are downloaded,
// so call it off the main thread.

#ifndef ASSPP_ATTEST_H
#define ASSPP_ATTEST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Sets the directory that holds one state file per device. It must be an
// absolute path; it is created if needed. Call once before asb_call.
// Returns 0 on success.
int32_t asb_configure(const char *state_dir);

// Runs one method: "health", "prepare", "machine-headers", "provision",
// "store-headers" or "kbsync". `request` is the method's JSON body, or NULL.
//
// Returns 0 on success, with the method's JSON in *response. Otherwise returns
// the HTTP status the service would have sent, with {"code","message"} JSON in
// *response. *response is always set and must be released with asb_free.
//
// `cancel_token` is a non-zero value the caller picks, unique among running
// calls, that asb_cancel can use to stop this call. Pass 0 for a call that
// cannot be canceled.
int32_t asb_call(const char *method,
                 const uint8_t *request, uint64_t request_length,
                 uint64_t cancel_token,
                 uint8_t **response, uint64_t *response_length);

// Stops the call started with this token. Safe from any thread, more than
// once, and after the call has finished.
void asb_cancel(uint64_t cancel_token);

// Releases a buffer returned by asb_call.
void asb_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
