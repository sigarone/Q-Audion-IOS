// SPDX-License-Identifier: MIT
// Q-Audion iOS: liboqs common implementation for SPM
// Standalone build without OpenSSL dependency

#include <oqs/oqsconfig.h>
#include <oqs/common.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- CPU extension detection (iOS/macOS) ----

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

OQS_API int OQS_CPU_has_extension(OQS_CPU_EXT ext) {
#if defined(__APPLE__) && defined(__aarch64__)
    switch (ext) {
        case OQS_CPU_EXT_ARM_AES:
        case OQS_CPU_EXT_ARM_SHA2:
        case OQS_CPU_EXT_ARM_NEON:
            return 1; // Always available on Apple Silicon
        case OQS_CPU_EXT_ARM_SHA3: {
            int p = 0;
            size_t p_len = sizeof(p);
            if (sysctlbyname("hw.optional.armv8_2_sha3", &p, &p_len, NULL, 0) == 0) {
                return (p != 0) ? 1 : 0;
            }
            return 0;
        }
        default:
            return 0;
    }
#else
    (void)ext;
    return 0;
#endif
}

OQS_API void OQS_init(void) {
    // No-op for standalone build
}

OQS_API void OQS_thread_stop(void) {
    // No-op for standalone build
}

OQS_API void OQS_destroy(void) {
    // No-op for standalone build
}

OQS_API const char *OQS_version(void) {
    return OQS_VERSION_TEXT;
}

// ---- Memory functions ----

OQS_API void *OQS_MEM_malloc(size_t size) {
    return malloc(size);
}

OQS_API void *OQS_MEM_calloc(size_t num_elements, size_t element_size) {
    return calloc(num_elements, element_size);
}

OQS_API char *OQS_MEM_strdup(const char *str) {
    return strdup(str);
}

OQS_API int OQS_MEM_secure_bcmp(const void *a, const void *b, size_t len) {
    uint8_t r = 0;
    for (size_t i = 0; i < len; i++) {
        r |= ((const uint8_t *)a)[i] ^ ((const uint8_t *)b)[i];
    }
    return 1 & ((-(unsigned int)r) >> 8);
}

OQS_API void OQS_MEM_cleanse(void *ptr, size_t len) {
    if (ptr == NULL) return;
#if defined(__APPLE__)
    // Apple provides explicit_bzero
    extern void explicit_bzero(void *, size_t);
    explicit_bzero(ptr, len);
#else
    volatile uint8_t *p = (volatile uint8_t *)ptr;
    for (size_t i = 0; i < len; i++) {
        p[i] = 0;
    }
#endif
}

OQS_API void OQS_MEM_secure_free(void *ptr, size_t len) {
    if (ptr != NULL) {
        OQS_MEM_cleanse(ptr, len);
        free(ptr);
    }
}

OQS_API void OQS_MEM_insecure_free(void *ptr) {
    free(ptr);
}
