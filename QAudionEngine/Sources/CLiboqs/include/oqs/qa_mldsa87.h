// SPDX-License-Identifier: MIT
// Q-Audion iOS: plain-C entry points over the vendored mldsa-native (ML-DSA-87, FIPS 204).
// Seed and signing randomness are supplied by the caller; this layer has no random number generator.

#ifndef QA_MLDSA87_H
#define QA_MLDSA87_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define QA_MLDSA87_SEED_BYTES 32
#define QA_MLDSA87_PUBLIC_KEY_BYTES 2592
#define QA_MLDSA87_SECRET_KEY_BYTES 4896
#define QA_MLDSA87_SIGNATURE_BYTES 4627
#define QA_MLDSA87_RND_BYTES 32
#define QA_MLDSA87_MAX_CONTEXT_BYTES 255

/// Key generation from a 32-byte seed (FIPS 204 ML-DSA.KeyGen_internal). Returns 0 on success.
int qa_mldsa87_keygen_from_seed(uint8_t pk[QA_MLDSA87_PUBLIC_KEY_BYTES],
                                uint8_t sk[QA_MLDSA87_SECRET_KEY_BYTES],
                                const uint8_t seed[QA_MLDSA87_SEED_BYTES]);

/// Pure-mode signature (message prefix 0x00 || len(ctx) || ctx) with the given 32 bytes of signing randomness.
/// Production callers pass fresh random bytes; 32 zero bytes give the deterministic variant. Returns 0 on success,
/// non-zero on failure or when ctxlen > 255 (the output is then zeroed).
int qa_mldsa87_sign_pure(uint8_t sig[QA_MLDSA87_SIGNATURE_BYTES],
                         const uint8_t *msg, size_t msglen,
                         const uint8_t *ctx, size_t ctxlen,
                         const uint8_t rnd[QA_MLDSA87_RND_BYTES],
                         const uint8_t sk[QA_MLDSA87_SECRET_KEY_BYTES]);

/// Pure-mode verification. Returns 0 when the signature is valid, non-zero otherwise (also when ctxlen > 255).
int qa_mldsa87_verify_pure(const uint8_t sig[QA_MLDSA87_SIGNATURE_BYTES],
                           const uint8_t *msg, size_t msglen,
                           const uint8_t *ctx, size_t ctxlen,
                           const uint8_t pk[QA_MLDSA87_PUBLIC_KEY_BYTES]);

#if defined(__cplusplus)
}
#endif

#endif // QA_MLDSA87_H
