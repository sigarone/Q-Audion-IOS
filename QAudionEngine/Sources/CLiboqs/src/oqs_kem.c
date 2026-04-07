// SPDX-License-Identifier: MIT
// Q-Audion iOS: KEM dispatcher and convenience API
// Routes OQS_KEM_new("ML-KEM-1024") to the real implementation

#include <oqs/kem.h>
#include <oqs/kem_ml_kem.h>

#include <string.h>

OQS_API OQS_KEM *OQS_KEM_new(const char *method_name) {
    if (method_name == NULL) {
        return NULL;
    }
#if defined(OQS_ENABLE_KEM_ml_kem_1024)
    if (strcmp(method_name, OQS_KEM_alg_ml_kem_1024) == 0) {
        return OQS_KEM_ml_kem_1024_new();
    }
#endif
    return NULL;
}

OQS_API void OQS_KEM_free(OQS_KEM *kem) {
    if (kem != NULL) {
        OQS_MEM_insecure_free(kem);
    }
}

OQS_API OQS_STATUS OQS_KEM_keypair(const OQS_KEM *kem,
                                    uint8_t *public_key, uint8_t *secret_key) {
    if (kem == NULL || kem->keypair == NULL) {
        return OQS_ERROR;
    }
    return kem->keypair(public_key, secret_key);
}

OQS_API OQS_STATUS OQS_KEM_encaps(const OQS_KEM *kem,
                                    uint8_t *ciphertext, uint8_t *shared_secret,
                                    const uint8_t *public_key) {
    if (kem == NULL || kem->encaps == NULL) {
        return OQS_ERROR;
    }
    return kem->encaps(ciphertext, shared_secret, public_key);
}

OQS_API OQS_STATUS OQS_KEM_decaps(const OQS_KEM *kem,
                                    uint8_t *shared_secret,
                                    const uint8_t *ciphertext,
                                    const uint8_t *secret_key) {
    if (kem == NULL || kem->decaps == NULL) {
        return OQS_ERROR;
    }
    return kem->decaps(shared_secret, ciphertext, secret_key);
}
