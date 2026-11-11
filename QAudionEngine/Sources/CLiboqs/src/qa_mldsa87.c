// SPDX-License-Identifier: MIT
// Q-Audion iOS: plain-C entry points over the vendored mldsa-native (see include/oqs/qa_mldsa87.h).

#include <oqs/qa_mldsa87.h>

#include <string.h>

#include "mldsa/mldsa_native.h"

// A zero-length message may arrive as a null pointer; the library is given a valid address instead.
static const uint8_t qa_empty_message[1] = {0};

_Static_assert(QA_MLDSA87_SEED_BYTES == MLDSA_SEEDBYTES, "seed size");
_Static_assert(QA_MLDSA87_PUBLIC_KEY_BYTES == MLDSA87_PUBLICKEYBYTES, "public key size");
_Static_assert(QA_MLDSA87_SECRET_KEY_BYTES == MLDSA87_SECRETKEYBYTES, "secret key size");
_Static_assert(QA_MLDSA87_SIGNATURE_BYTES == MLDSA87_BYTES, "signature size");
_Static_assert(QA_MLDSA87_RND_BYTES == MLDSA_RNDBYTES, "randomness size");

int qa_mldsa87_keygen_from_seed(uint8_t pk[QA_MLDSA87_PUBLIC_KEY_BYTES],
                                uint8_t sk[QA_MLDSA87_SECRET_KEY_BYTES],
                                const uint8_t seed[QA_MLDSA87_SEED_BYTES]) {
    return qa_mldsa87_keypair_internal(pk, sk, seed);
}

int qa_mldsa87_sign_pure(uint8_t sig[QA_MLDSA87_SIGNATURE_BYTES],
                         const uint8_t *msg, size_t msglen,
                         const uint8_t *ctx, size_t ctxlen,
                         const uint8_t rnd[QA_MLDSA87_RND_BYTES],
                         const uint8_t sk[QA_MLDSA87_SECRET_KEY_BYTES]) {
    if (ctxlen > QA_MLDSA87_MAX_CONTEXT_BYTES) {
        memset(sig, 0, QA_MLDSA87_SIGNATURE_BYTES);
        return -1;
    }
    if (msg == NULL) {
        msg = qa_empty_message;
    }
    uint8_t pre[2 + QA_MLDSA87_MAX_CONTEXT_BYTES];
    pre[0] = 0;
    pre[1] = (uint8_t)ctxlen;
    if (ctxlen > 0) {
        memcpy(pre + 2, ctx, ctxlen);
    }
    return qa_mldsa87_signature_internal(sig, msg, msglen, pre, 2 + ctxlen, rnd, sk, 0);
}

int qa_mldsa87_verify_pure(const uint8_t sig[QA_MLDSA87_SIGNATURE_BYTES],
                           const uint8_t *msg, size_t msglen,
                           const uint8_t *ctx, size_t ctxlen,
                           const uint8_t pk[QA_MLDSA87_PUBLIC_KEY_BYTES]) {
    if (ctxlen > QA_MLDSA87_MAX_CONTEXT_BYTES) {
        return -1;
    }
    if (msg == NULL) {
        msg = qa_empty_message;
    }
    uint8_t pre[2 + QA_MLDSA87_MAX_CONTEXT_BYTES];
    pre[0] = 0;
    pre[1] = (uint8_t)ctxlen;
    if (ctxlen > 0) {
        memcpy(pre + 2, ctx, ctxlen);
    }
    return qa_mldsa87_verify_internal(sig, msg, msglen, pre, 2 + ctxlen, pk, 0);
}
