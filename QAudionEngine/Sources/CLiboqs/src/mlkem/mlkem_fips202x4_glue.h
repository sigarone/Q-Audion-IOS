// SPDX-License-Identifier: Apache-2.0 OR ISC OR MIT
// Q-Audion iOS: FIPS-202 x4 glue for mlkem-native

#ifndef MLK_FIPS202X4_GLUE_H
#define MLK_FIPS202X4_GLUE_H

// Use header search path (pqclean_shims is in headerSearchPath)
#include "fips202x4.h"

#define mlk_shake128x4ctx shake128x4ctx
#define mlk_shake128x4_absorb_once shake128x4_absorb_once
#define mlk_shake128x4_squeezeblocks shake128x4_squeezeblocks
#define mlk_shake128x4_init shake128x4_init
#define mlk_shake128x4_release shake128x4_release
#define mlk_shake256x4 shake256x4

#endif // MLK_FIPS202X4_GLUE_H
