// SPDX-License-Identifier: MIT
// Q-Audion iOS: Minimal FIPS-202 x4 shim (serial fallback)
// Provides shake128x4/shake256x4 using sequential shake128/shake256

#ifndef FIPS202X4_H
#define FIPS202X4_H

#include "fips202.h"

// x4 context: just 4 independent contexts
typedef struct {
    shake128incctx ctx[4];
} shake128x4ctx;

static inline void shake128x4_init(shake128x4ctx *state) {
    for (int i = 0; i < 4; i++) shake128_inc_init(&state->ctx[i]);
}

static inline void shake128x4_absorb_once(shake128x4ctx *state,
    const uint8_t *in0, const uint8_t *in1,
    const uint8_t *in2, const uint8_t *in3, size_t inlen) {
    shake128_absorb_once(&state->ctx[0], in0, inlen);
    shake128_absorb_once(&state->ctx[1], in1, inlen);
    shake128_absorb_once(&state->ctx[2], in2, inlen);
    shake128_absorb_once(&state->ctx[3], in3, inlen);
}

static inline void shake128x4_squeezeblocks(uint8_t *out0, uint8_t *out1,
    uint8_t *out2, uint8_t *out3, size_t nblocks, shake128x4ctx *state) {
    size_t len = nblocks * SHAKE128_RATE;
    OQS_SHA3_shake128_inc_squeeze(out0, len, &state->ctx[0]);
    OQS_SHA3_shake128_inc_squeeze(out1, len, &state->ctx[1]);
    OQS_SHA3_shake128_inc_squeeze(out2, len, &state->ctx[2]);
    OQS_SHA3_shake128_inc_squeeze(out3, len, &state->ctx[3]);
}

static inline void shake128x4_release(shake128x4ctx *state) {
    for (int i = 0; i < 4; i++) shake128_inc_ctx_release(&state->ctx[i]);
}

static inline void shake256x4(uint8_t *out0, uint8_t *out1,
    uint8_t *out2, uint8_t *out3, size_t outlen,
    const uint8_t *in0, const uint8_t *in1,
    const uint8_t *in2, const uint8_t *in3, size_t inlen) {
    shake256(out0, outlen, in0, inlen);
    shake256(out1, outlen, in1, inlen);
    shake256(out2, outlen, in2, inlen);
    shake256(out3, outlen, in3, inlen);
}

#endif // FIPS202X4_H
