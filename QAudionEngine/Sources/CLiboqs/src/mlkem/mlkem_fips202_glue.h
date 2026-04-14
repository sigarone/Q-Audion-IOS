// SPDX-License-Identifier: Apache-2.0 OR ISC OR MIT
// Q-Audion iOS: FIPS-202 glue for mlkem-native
// Maps mlk_xxx SHA3 functions to pqclean_shims FIPS-202

#ifndef MLK_FIPS202_GLUE_H
#define MLK_FIPS202_GLUE_H

// Use header search path (pqclean_shims is in headerSearchPath)
#include "fips202.h"

// Map mlkem-native FIPS-202 names to OQS pqclean shims
#define mlk_shake128ctx shake128ctx
#define mlk_shake128_absorb_once shake128_absorb_once
#define mlk_shake128_squeezeblocks shake128_squeezeblocks
#define mlk_shake128_init shake128_init
#define mlk_shake128_release shake128_release
#define mlk_shake256 shake256
#define mlk_sha3_256 sha3_256
#define mlk_sha3_512 sha3_512

#endif // MLK_FIPS202_GLUE_H
