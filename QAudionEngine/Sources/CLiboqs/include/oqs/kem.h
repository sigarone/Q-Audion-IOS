// SPDX-License-Identifier: MIT
// Q-Audion iOS: liboqs KEM header for SPM
// Real liboqs-compatible KEM API

#ifndef OQS_KEM_H
#define OQS_KEM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <oqs/common.h>

#if defined(__cplusplus)
extern "C" {
#endif

// KEM structure -- matches real liboqs exactly
typedef struct OQS_KEM {
    const char *method_name;
    const char *alg_version;

    uint8_t claimed_nist_level;
    bool ind_cca;

    size_t length_public_key;
    size_t length_secret_key;
    size_t length_ciphertext;
    size_t length_shared_secret;
    size_t length_keypair_seed;
    size_t length_encaps_seed;

    OQS_STATUS (*keypair)(uint8_t *public_key, uint8_t *secret_key);
    OQS_STATUS (*keypair_derand)(uint8_t *public_key, uint8_t *secret_key,
                                 const uint8_t *seed);
    OQS_STATUS (*encaps)(uint8_t *ciphertext, uint8_t *shared_secret,
                         const uint8_t *public_key);
    OQS_STATUS (*encaps_derand)(uint8_t *ciphertext, uint8_t *shared_secret,
                                const uint8_t *public_key, const uint8_t *seed);
    OQS_STATUS (*decaps)(uint8_t *shared_secret, const uint8_t *ciphertext,
                         const uint8_t *secret_key);
} OQS_KEM;

// Constructor / Destructor
OQS_API OQS_KEM *OQS_KEM_new(const char *method_name);
OQS_API void OQS_KEM_free(OQS_KEM *kem);

// Convenience wrappers (call through function pointers)
OQS_API OQS_STATUS OQS_KEM_keypair(const OQS_KEM *kem,
                                    uint8_t *public_key, uint8_t *secret_key);
OQS_API OQS_STATUS OQS_KEM_encaps(const OQS_KEM *kem,
                                    uint8_t *ciphertext, uint8_t *shared_secret,
                                    const uint8_t *public_key);
OQS_API OQS_STATUS OQS_KEM_decaps(const OQS_KEM *kem,
                                    uint8_t *shared_secret,
                                    const uint8_t *ciphertext,
                                    const uint8_t *secret_key);

#if defined(__cplusplus)
}
#endif

#endif // OQS_KEM_H
