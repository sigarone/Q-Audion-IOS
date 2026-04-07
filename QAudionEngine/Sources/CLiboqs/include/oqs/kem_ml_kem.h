// SPDX-License-Identifier: MIT
// Q-Audion iOS: ML-KEM-1024 specific header

#ifndef OQS_KEM_ML_KEM_H
#define OQS_KEM_ML_KEM_H

#include <oqs/oqs.h>

#if defined(OQS_ENABLE_KEM_ml_kem_1024)

#define OQS_KEM_ml_kem_1024_length_public_key 1568
#define OQS_KEM_ml_kem_1024_length_secret_key 3168
#define OQS_KEM_ml_kem_1024_length_ciphertext 1568
#define OQS_KEM_ml_kem_1024_length_shared_secret 32
#define OQS_KEM_ml_kem_1024_length_keypair_seed 64
#define OQS_KEM_ml_kem_1024_length_encaps_seed 32

OQS_KEM *OQS_KEM_ml_kem_1024_new(void);
OQS_API OQS_STATUS OQS_KEM_ml_kem_1024_keypair(uint8_t *public_key, uint8_t *secret_key);
OQS_API OQS_STATUS OQS_KEM_ml_kem_1024_keypair_derand(uint8_t *public_key, uint8_t *secret_key, const uint8_t *seed);
OQS_API OQS_STATUS OQS_KEM_ml_kem_1024_encaps(uint8_t *ciphertext, uint8_t *shared_secret, const uint8_t *public_key);
OQS_API OQS_STATUS OQS_KEM_ml_kem_1024_encaps_derand(uint8_t *ciphertext, uint8_t *shared_secret, const uint8_t *public_key, const uint8_t *seed);
OQS_API OQS_STATUS OQS_KEM_ml_kem_1024_decaps(uint8_t *shared_secret, const uint8_t *ciphertext, const uint8_t *secret_key);

#endif // OQS_ENABLE_KEM_ml_kem_1024

#endif // OQS_KEM_ML_KEM_H
