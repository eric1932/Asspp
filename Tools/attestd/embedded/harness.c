// Smoke test for AssppAttest.framework: configure, health, prepare, kbsync.
//
// kbsync needs no Apple account; the device ID and DSID below are made up.
// Prints statuses, sizes and seconds. The kbsync blob itself is not printed.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "AssppAttest.h"

static double seconds_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static int run(const char *method, const char *json, int print_body) {
    uint8_t *response = NULL;
    uint64_t length = 0;
    double start = seconds_now();
    int32_t status = asb_call(method, (const uint8_t *)json, json ? strlen(json) : 0, 0, &response, &length);
    double elapsed = seconds_now() - start;

    printf("%s: status=%d seconds=%.2f bytes=%llu", method, status, elapsed, (unsigned long long)length);
    if ((print_body || status != 0) && response != NULL) {
        printf(" body=%.*s", (int)(length > 400 ? 400 : length), (const char *)response);
    }
    printf("\n");
    fflush(stdout);

    asb_free(response);
    return status;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: harness <state-dir> [kbsync-runs]\n");
        return 2;
    }

    if (asb_configure(argv[1]) != 0) {
        fprintf(stderr, "configure failed\n");
        return 1;
    }

    int runs = argc > 2 ? atoi(argv[2]) : 2;
    int failed = run("health", NULL, 1) != 0;
    failed |= run("prepare", "{}", 0) != 0;
    failed |= run("health", NULL, 1) != 0; // assetBytes: how much the first prepare downloaded
    for (int index = 0; index < runs; index++) {
        failed |= run("kbsync", "{\"guid\":\"02005E102030\",\"dsid\":\"12345678901\"}", 0) != 0;
    }

    return failed;
}
