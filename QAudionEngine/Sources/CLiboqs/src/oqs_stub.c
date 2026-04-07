#include "oqs.h"
#include <stdlib.h>
#include <string.h>

// Stub implementation - returns random bytes for testing
// Real liboqs sources replace this file

static OQS_KEM kem_instance = {
    .method_name = "ML-KEM-1024",
    .length_public_key = OQS_KEM_ml_kem_1024_length_public_key,
    .length_secret_key = OQS_KEM_ml_kem_1024_length_secret_key,
    .length_ciphertext = OQS_KEM_ml_kem_1024_length_ciphertext,
    .length_shared_secret = OQS_KEM_ml_kem_1024_length_shared_secret
};

OQS_KEM *OQS_KEM_new(const char *method_name) {
    (void)method_name;
    return &kem_instance;
}

void OQS_KEM_free(OQS_KEM *kem) {
    (void)kem;
}

int OQS_KEM_keypair(const OQS_KEM *kem, uint8_t *public_key, uint8_t *secret_key) {
    // Stub: fill with pseudo-random pattern
    for (size_t i = 0; i < kem->length_public_key; i++) public_key[i] = (uint8_t)(i & 0xFF);
    for (size_t i = 0; i < kem->length_secret_key; i++) secret_key[i] = (uint8_t)((i + 0x42) & 0xFF);
    return OQS_SUCCESS;
}

int OQS_KEM_encaps(const OQS_KEM *kem, uint8_t *ciphertext, uint8_t *shared_secret, const uint8_t *public_key) {
    (void)public_key;
    for (size_t i = 0; i < kem->length_ciphertext; i++) ciphertext[i] = (uint8_t)((i + 0xAA) & 0xFF);
    for (size_t i = 0; i < kem->length_shared_secret; i++) shared_secret[i] = (uint8_t)((i + 0xBB) & 0xFF);
    return OQS_SUCCESS;
}

int OQS_KEM_decaps(const OQS_KEM *kem, uint8_t *shared_secret, const uint8_t *ciphertext, const uint8_t *secret_key) {
    (void)ciphertext;
    (void)secret_key;
    for (size_t i = 0; i < kem->length_shared_secret; i++) shared_secret[i] = (uint8_t)((i + 0xBB) & 0xFF);
    return OQS_SUCCESS;
}

void OQS_MEM_cleanse(void *ptr, size_t len) {
    volatile uint8_t *p = (volatile uint8_t *)ptr;
    for (size_t i = 0; i < len; i++) p[i] = 0;
}
