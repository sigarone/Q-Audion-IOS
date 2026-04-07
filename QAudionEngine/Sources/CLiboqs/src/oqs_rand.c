// SPDX-License-Identifier: MIT
// Q-Audion iOS: liboqs random number generation for SPM
// Uses arc4random_buf on Apple platforms, /dev/urandom elsewhere

#include <oqs/rand.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <stdlib.h> // arc4random_buf
#elif defined(_WIN32)
#include <windows.h>
#include <wincrypt.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

static void OQS_randombytes_system(uint8_t *random_array, size_t bytes_to_read);

static void (*oqs_randombytes_algorithm)(uint8_t *, size_t) = &OQS_randombytes_system;

OQS_API OQS_STATUS OQS_randombytes_switch_algorithm(const char *algorithm) {
    (void)algorithm;
    oqs_randombytes_algorithm = &OQS_randombytes_system;
    return OQS_SUCCESS;
}

OQS_API void OQS_randombytes_custom_algorithm(void (*algorithm_ptr)(uint8_t *, size_t)) {
    oqs_randombytes_algorithm = algorithm_ptr;
}

OQS_API void OQS_randombytes(uint8_t *random_array, size_t bytes_to_read) {
    oqs_randombytes_algorithm(random_array, bytes_to_read);
}

// Platform-specific secure random
#if defined(__APPLE__)
static void OQS_randombytes_system(uint8_t *random_array, size_t bytes_to_read) {
    arc4random_buf(random_array, bytes_to_read);
}
#elif defined(_WIN32)
static void OQS_randombytes_system(uint8_t *random_array, size_t bytes_to_read) {
    HCRYPTPROV hCryptProv;
    if (!CryptAcquireContext(&hCryptProv, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT) ||
        !CryptGenRandom(hCryptProv, (DWORD)bytes_to_read, random_array)) {
        exit(EXIT_FAILURE);
    }
    CryptReleaseContext(hCryptProv, 0);
}
#else
static void OQS_randombytes_system(uint8_t *random_array, size_t bytes_to_read) {
    FILE *handle = fopen("/dev/urandom", "rb");
    if (!handle) {
        perror("OQS_randombytes");
        exit(EXIT_FAILURE);
    }
    size_t bytes_read = fread(random_array, 1, bytes_to_read, handle);
    if (bytes_read < bytes_to_read || ferror(handle)) {
        perror("OQS_randombytes");
        exit(EXIT_FAILURE);
    }
    fclose(handle);
}
#endif
