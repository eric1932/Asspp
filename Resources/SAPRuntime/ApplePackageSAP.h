#ifndef APPLE_PACKAGE_SAP_H
#define APPLE_PACKAGE_SAP_H
#include <stdint.h>

// Handles are opaque IDs, never pointers to Go memory. Returned buffers/errors
// are C allocations and must be released with apsap_free. No function signs in.
uint64_t apsap_create(const uint8_t *hardware, uint64_t count, const char *cache_directory, char **error);
int32_t apsap_prepare(uint64_t handle, char **error);
int32_t apsap_exchange(uint64_t handle, uint32_t version, const uint8_t *input, uint64_t count,
                       uint8_t **output, uint64_t *output_count, int32_t *state, char **error);
int32_t apsap_sign(uint64_t handle, const uint8_t *input, uint64_t count,
                   uint8_t **output, uint64_t *output_count, char **error);
void apsap_cancel(uint64_t handle);
void apsap_close(uint64_t handle);
void apsap_free(void *allocation);
#endif
