/**
 * \file xkcp_sha3.c
 * \brief OQS SHA3 API using XKCP Keccak (portable C, no dispatch)
 * Adapted from liboqs for Q-Audion iOS standalone SPM build.
 *
 * SPDX-License-Identifier: MIT
 */

#include <oqs/sha3.h>
#include <oqs/common.h>

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Forward-declare the portable KeccakP-1600 functions
extern void KeccakP1600_Initialize(void *state);
extern void KeccakP1600_AddByte(void *state, uint8_t byte, unsigned int offset);
extern void KeccakP1600_AddBytes(void *state, const uint8_t *data, unsigned int offset, unsigned int length);
extern void KeccakP1600_Permute_24rounds(void *state);
extern void KeccakP1600_ExtractBytes(const void *state, uint8_t *data, unsigned int offset, unsigned int length);

#define KECCAK_CTX_ALIGNMENT 32
#define _KECCAK_CTX_BYTES (200+sizeof(uint64_t))
#define KECCAK_CTX_BYTES (KECCAK_CTX_ALIGNMENT * \
  ((_KECCAK_CTX_BYTES + KECCAK_CTX_ALIGNMENT - 1)/KECCAK_CTX_ALIGNMENT))

// Simple aligned alloc for SHA3 contexts
static void *sha3_aligned_alloc(size_t alignment, size_t size) {
#if defined(__APPLE__) || defined(__linux__)
    void *ptr = NULL;
    if (posix_memalign(&ptr, alignment, size) != 0) return NULL;
    return ptr;
#else
    (void)alignment;
    return malloc(size);
#endif
}

static void sha3_aligned_free(void *ptr, size_t len) {
    if (ptr) {
        OQS_MEM_cleanse(ptr, len);
        free(ptr);
    }
}

static void keccak_inc_reset(uint64_t *s) {
    KeccakP1600_Initialize(s);
    s[25] = 0;
}

static void keccak_inc_absorb(uint64_t *s, uint32_t r, const uint8_t *m, size_t mlen) {
    uint64_t c = r - s[25];

    if (s[25] && mlen >= c) {
        KeccakP1600_AddBytes(s, m, (unsigned int)s[25], (unsigned int)c);
        KeccakP1600_Permute_24rounds(s);
        mlen -= c;
        m += c;
        s[25] = 0;
    }

    while (mlen >= r) {
        KeccakP1600_AddBytes(s, m, 0, r);
        KeccakP1600_Permute_24rounds(s);
        mlen -= r;
        m += r;
    }

    KeccakP1600_AddBytes(s, m, (unsigned int)s[25], (unsigned int)mlen);
    s[25] += mlen;
}

static void keccak_inc_finalize(uint64_t *s, uint32_t r, uint8_t p) {
    KeccakP1600_AddByte(s, p, (unsigned int)s[25]);
    KeccakP1600_AddByte(s, 0x80, (unsigned int)(r - 1));
    s[25] = 0;
}

static void keccak_inc_squeeze(uint8_t *h, size_t outlen, uint64_t *s, uint32_t r) {
    while (outlen > s[25]) {
        KeccakP1600_ExtractBytes(s, h, (unsigned int)(r - s[25]), (unsigned int)s[25]);
        KeccakP1600_Permute_24rounds(s);
        h += s[25];
        outlen -= s[25];
        s[25] = r;
    }
    KeccakP1600_ExtractBytes(s, h, (unsigned int)(r - s[25]), (unsigned int)outlen);
    s[25] -= outlen;
}

/* ---- SHA3-256 ---- */
void OQS_SHA3_sha3_256(uint8_t *output, const uint8_t *input, size_t inplen) {
    OQS_SHA3_sha3_256_inc_ctx s;
    OQS_SHA3_sha3_256_inc_init(&s);
    OQS_SHA3_sha3_256_inc_absorb(&s, input, inplen);
    OQS_SHA3_sha3_256_inc_finalize(output, &s);
    OQS_SHA3_sha3_256_inc_ctx_release(&s);
}

void OQS_SHA3_sha3_256_inc_init(OQS_SHA3_sha3_256_inc_ctx *state) {
    state->ctx = sha3_aligned_alloc(KECCAK_CTX_ALIGNMENT, KECCAK_CTX_BYTES);
    OQS_EXIT_IF_NULLPTR(state->ctx, "SHA3");
    keccak_inc_reset((uint64_t *)state->ctx);
}

void OQS_SHA3_sha3_256_inc_absorb(OQS_SHA3_sha3_256_inc_ctx *state, const uint8_t *input, size_t inlen) {
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHA3_256_RATE, input, inlen);
}

void OQS_SHA3_sha3_256_inc_finalize(uint8_t *output, OQS_SHA3_sha3_256_inc_ctx *state) {
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHA3_256_RATE, 0x06);
    keccak_inc_squeeze(output, 32, (uint64_t *)state->ctx, OQS_SHA3_SHA3_256_RATE);
}

void OQS_SHA3_sha3_256_inc_ctx_release(OQS_SHA3_sha3_256_inc_ctx *state) {
    sha3_aligned_free(state->ctx, KECCAK_CTX_BYTES);
}

void OQS_SHA3_sha3_256_inc_ctx_clone(OQS_SHA3_sha3_256_inc_ctx *dest, const OQS_SHA3_sha3_256_inc_ctx *src) {
    memcpy(dest->ctx, src->ctx, KECCAK_CTX_BYTES);
}

void OQS_SHA3_sha3_256_inc_ctx_reset(OQS_SHA3_sha3_256_inc_ctx *state) {
    keccak_inc_reset((uint64_t *)state->ctx);
}

/* ---- SHA3-384 ---- */
void OQS_SHA3_sha3_384(uint8_t *output, const uint8_t *input, size_t inplen) {
    OQS_SHA3_sha3_384_inc_ctx s;
    OQS_SHA3_sha3_384_inc_init(&s);
    OQS_SHA3_sha3_384_inc_absorb(&s, input, inplen);
    OQS_SHA3_sha3_384_inc_finalize(output, &s);
    OQS_SHA3_sha3_384_inc_ctx_release(&s);
}

void OQS_SHA3_sha3_384_inc_init(OQS_SHA3_sha3_384_inc_ctx *state) {
    state->ctx = sha3_aligned_alloc(KECCAK_CTX_ALIGNMENT, KECCAK_CTX_BYTES);
    OQS_EXIT_IF_NULLPTR(state->ctx, "SHA3");
    keccak_inc_reset((uint64_t *)state->ctx);
}
void OQS_SHA3_sha3_384_inc_absorb(OQS_SHA3_sha3_384_inc_ctx *state, const uint8_t *input, size_t inlen) {
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHA3_384_RATE, input, inlen);
}
void OQS_SHA3_sha3_384_inc_finalize(uint8_t *output, OQS_SHA3_sha3_384_inc_ctx *state) {
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHA3_384_RATE, 0x06);
    keccak_inc_squeeze(output, 48, (uint64_t *)state->ctx, OQS_SHA3_SHA3_384_RATE);
}
void OQS_SHA3_sha3_384_inc_ctx_release(OQS_SHA3_sha3_384_inc_ctx *state) {
    sha3_aligned_free(state->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_sha3_384_inc_ctx_clone(OQS_SHA3_sha3_384_inc_ctx *dest, const OQS_SHA3_sha3_384_inc_ctx *src) {
    memcpy(dest->ctx, src->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_sha3_384_inc_ctx_reset(OQS_SHA3_sha3_384_inc_ctx *state) {
    keccak_inc_reset((uint64_t *)state->ctx);
}

/* ---- SHA3-512 ---- */
void OQS_SHA3_sha3_512(uint8_t *output, const uint8_t *input, size_t inplen) {
    OQS_SHA3_sha3_512_inc_ctx s;
    OQS_SHA3_sha3_512_inc_init(&s);
    OQS_SHA3_sha3_512_inc_absorb(&s, input, inplen);
    OQS_SHA3_sha3_512_inc_finalize(output, &s);
    OQS_SHA3_sha3_512_inc_ctx_release(&s);
}

void OQS_SHA3_sha3_512_inc_init(OQS_SHA3_sha3_512_inc_ctx *state) {
    state->ctx = sha3_aligned_alloc(KECCAK_CTX_ALIGNMENT, KECCAK_CTX_BYTES);
    OQS_EXIT_IF_NULLPTR(state->ctx, "SHA3");
    keccak_inc_reset((uint64_t *)state->ctx);
}
void OQS_SHA3_sha3_512_inc_absorb(OQS_SHA3_sha3_512_inc_ctx *state, const uint8_t *input, size_t inlen) {
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHA3_512_RATE, input, inlen);
}
void OQS_SHA3_sha3_512_inc_finalize(uint8_t *output, OQS_SHA3_sha3_512_inc_ctx *state) {
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHA3_512_RATE, 0x06);
    keccak_inc_squeeze(output, 64, (uint64_t *)state->ctx, OQS_SHA3_SHA3_512_RATE);
}
void OQS_SHA3_sha3_512_inc_ctx_release(OQS_SHA3_sha3_512_inc_ctx *state) {
    sha3_aligned_free(state->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_sha3_512_inc_ctx_clone(OQS_SHA3_sha3_512_inc_ctx *dest, const OQS_SHA3_sha3_512_inc_ctx *src) {
    memcpy(dest->ctx, src->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_sha3_512_inc_ctx_reset(OQS_SHA3_sha3_512_inc_ctx *state) {
    keccak_inc_reset((uint64_t *)state->ctx);
}

/* ---- SHAKE128 ---- */
void OQS_SHA3_shake128(uint8_t *output, size_t outlen, const uint8_t *input, size_t inplen) {
    OQS_SHA3_shake128_inc_ctx s;
    OQS_SHA3_shake128_inc_init(&s);
    OQS_SHA3_shake128_inc_absorb(&s, input, inplen);
    OQS_SHA3_shake128_inc_finalize(&s);
    OQS_SHA3_shake128_inc_squeeze(output, outlen, &s);
    OQS_SHA3_shake128_inc_ctx_release(&s);
}

void OQS_SHA3_shake128_inc_init(OQS_SHA3_shake128_inc_ctx *state) {
    state->ctx = sha3_aligned_alloc(KECCAK_CTX_ALIGNMENT, KECCAK_CTX_BYTES);
    OQS_EXIT_IF_NULLPTR(state->ctx, "SHA3");
    keccak_inc_reset((uint64_t *)state->ctx);
}
void OQS_SHA3_shake128_inc_absorb(OQS_SHA3_shake128_inc_ctx *state, const uint8_t *input, size_t inlen) {
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHAKE128_RATE, input, inlen);
}
void OQS_SHA3_shake128_inc_finalize(OQS_SHA3_shake128_inc_ctx *state) {
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHAKE128_RATE, 0x1F);
}
void OQS_SHA3_shake128_inc_squeeze(uint8_t *output, size_t outlen, OQS_SHA3_shake128_inc_ctx *state) {
    keccak_inc_squeeze(output, outlen, (uint64_t *)state->ctx, OQS_SHA3_SHAKE128_RATE);
}
void OQS_SHA3_shake128_inc_ctx_clone(OQS_SHA3_shake128_inc_ctx *dest, const OQS_SHA3_shake128_inc_ctx *src) {
    memcpy(dest->ctx, src->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_shake128_inc_ctx_release(OQS_SHA3_shake128_inc_ctx *state) {
    sha3_aligned_free(state->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_shake128_inc_ctx_reset(OQS_SHA3_shake128_inc_ctx *state) {
    keccak_inc_reset((uint64_t *)state->ctx);
}

/* OQS_SHA3_shake128_absorb_once: used by pqclean shim */
void OQS_SHA3_shake128_absorb_once(OQS_SHA3_shake128_inc_ctx *state, const uint8_t *in, size_t inlen) {
    keccak_inc_reset((uint64_t *)state->ctx);
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHAKE128_RATE, in, inlen);
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHAKE128_RATE, 0x1F);
}

/* ---- SHAKE256 ---- */
void OQS_SHA3_shake256(uint8_t *output, size_t outlen, const uint8_t *input, size_t inplen) {
    OQS_SHA3_shake256_inc_ctx s;
    OQS_SHA3_shake256_inc_init(&s);
    OQS_SHA3_shake256_inc_absorb(&s, input, inplen);
    OQS_SHA3_shake256_inc_finalize(&s);
    OQS_SHA3_shake256_inc_squeeze(output, outlen, &s);
    OQS_SHA3_shake256_inc_ctx_release(&s);
}

void OQS_SHA3_shake256_inc_init(OQS_SHA3_shake256_inc_ctx *state) {
    state->ctx = sha3_aligned_alloc(KECCAK_CTX_ALIGNMENT, KECCAK_CTX_BYTES);
    OQS_EXIT_IF_NULLPTR(state->ctx, "SHA3");
    keccak_inc_reset((uint64_t *)state->ctx);
}
void OQS_SHA3_shake256_inc_absorb(OQS_SHA3_shake256_inc_ctx *state, const uint8_t *input, size_t inlen) {
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHAKE256_RATE, input, inlen);
}
void OQS_SHA3_shake256_inc_finalize(OQS_SHA3_shake256_inc_ctx *state) {
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHAKE256_RATE, 0x1F);
}
void OQS_SHA3_shake256_inc_squeeze(uint8_t *output, size_t outlen, OQS_SHA3_shake256_inc_ctx *state) {
    keccak_inc_squeeze(output, outlen, state->ctx, OQS_SHA3_SHAKE256_RATE);
}
void OQS_SHA3_shake256_inc_ctx_release(OQS_SHA3_shake256_inc_ctx *state) {
    sha3_aligned_free(state->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_shake256_inc_ctx_clone(OQS_SHA3_shake256_inc_ctx *dest, const OQS_SHA3_shake256_inc_ctx *src) {
    memcpy(dest->ctx, src->ctx, KECCAK_CTX_BYTES);
}
void OQS_SHA3_shake256_inc_ctx_reset(OQS_SHA3_shake256_inc_ctx *state) {
    keccak_inc_reset((uint64_t *)state->ctx);
}

/* OQS_SHA3_shake256_absorb_once: used by pqclean shim */
void OQS_SHA3_shake256_absorb_once(OQS_SHA3_shake256_inc_ctx *state, const uint8_t *in, size_t inlen) {
    keccak_inc_reset((uint64_t *)state->ctx);
    keccak_inc_absorb((uint64_t *)state->ctx, OQS_SHA3_SHAKE256_RATE, in, inlen);
    keccak_inc_finalize((uint64_t *)state->ctx, OQS_SHA3_SHAKE256_RATE, 0x1F);
}

/* Callback setter (no-op in standalone build) */
void OQS_SHA3_set_callbacks(struct OQS_SHA3_callbacks *new_callbacks) {
    (void)new_callbacks;
}
