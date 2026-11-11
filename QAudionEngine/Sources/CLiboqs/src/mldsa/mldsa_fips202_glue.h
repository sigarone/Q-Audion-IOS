/* SPDX-License-Identifier: Apache-2.0 OR ISC OR MIT */
/*
 * Q-Audion iOS: FIPS-202 glue for mldsa-native. Maps the incremental SHAKE API that mldsa-native
 * expects (FIPS202.md of the upstream tree) onto the OQS_SHA3_* functions already compiled in CLiboqs.
 * The OQS contexts own heap state: every init is matched by a release (mldsa-native does this).
 */
#ifndef MLDSA_FIPS202_GLUE_H
#define MLDSA_FIPS202_GLUE_H

#include <stddef.h>
#include <stdint.h>

#include <oqs/sha3.h>

/* MLD_INLINE comes from mldsa-native's sys.h, which is always included first. */

#define SHAKE128_RATE 168
#define SHAKE256_RATE 136

typedef OQS_SHA3_shake128_inc_ctx mld_shake128ctx;
typedef OQS_SHA3_shake256_inc_ctx mld_shake256ctx;

static MLD_INLINE void mld_shake128_init(mld_shake128ctx *state)
{
  OQS_SHA3_shake128_inc_init(state);
}

static MLD_INLINE void mld_shake128_absorb(mld_shake128ctx *state, const uint8_t *in,
                                    size_t inlen)
{
  OQS_SHA3_shake128_inc_absorb(state, in, inlen);
}

static MLD_INLINE void mld_shake128_finalize(mld_shake128ctx *state)
{
  OQS_SHA3_shake128_inc_finalize(state);
}

static MLD_INLINE void mld_shake128_squeeze(uint8_t *out, size_t outlen,
                                     mld_shake128ctx *state)
{
  OQS_SHA3_shake128_inc_squeeze(out, outlen, state);
}

static MLD_INLINE void mld_shake128_release(mld_shake128ctx *state)
{
  OQS_SHA3_shake128_inc_ctx_release(state);
}

static MLD_INLINE void mld_shake256_init(mld_shake256ctx *state)
{
  OQS_SHA3_shake256_inc_init(state);
}

static MLD_INLINE void mld_shake256_absorb(mld_shake256ctx *state, const uint8_t *in,
                                    size_t inlen)
{
  OQS_SHA3_shake256_inc_absorb(state, in, inlen);
}

static MLD_INLINE void mld_shake256_finalize(mld_shake256ctx *state)
{
  OQS_SHA3_shake256_inc_finalize(state);
}

static MLD_INLINE void mld_shake256_squeeze(uint8_t *out, size_t outlen,
                                     mld_shake256ctx *state)
{
  OQS_SHA3_shake256_inc_squeeze(out, outlen, state);
}

static MLD_INLINE void mld_shake256_release(mld_shake256ctx *state)
{
  OQS_SHA3_shake256_inc_ctx_release(state);
}

static MLD_INLINE void mld_shake256(uint8_t *out, size_t outlen, const uint8_t *in,
                             size_t inlen)
{
  OQS_SHA3_shake256(out, outlen, in, inlen);
}

#endif /* MLDSA_FIPS202_GLUE_H */
