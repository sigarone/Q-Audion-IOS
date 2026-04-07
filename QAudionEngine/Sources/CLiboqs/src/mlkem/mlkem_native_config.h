// SPDX-License-Identifier: Apache-2.0 OR ISC OR MIT
// Q-Audion iOS: mlkem-native configuration for ML-KEM-1024
// This replaces the liboqs integration config_c.h for standalone SPM build

#ifndef MLK_MLKEM_NATIVE_CONFIG_H
#define MLK_MLKEM_NATIVE_CONFIG_H

// ML-KEM-1024 (FIPS 203, NIST Level 5)
#define MLK_CONFIG_PARAMETER_SET 1024

// Namespace prefix matching liboqs expectations
#define MLK_CONFIG_NAMESPACE_PREFIX PQCP_MLKEM_NATIVE_MLKEM1024_C

// Use our custom FIPS-202 glue pointing to pqclean_shims
#define MLK_CONFIG_FIPS202_CUSTOM_HEADER "mlkem_fips202_glue.h"
#define MLK_CONFIG_FIPS202X4_CUSTOM_HEADER "mlkem_fips202x4_glue.h"

// Use custom randombytes via liboqs OQS_randombytes
#define MLK_CONFIG_CUSTOM_RANDOMBYTES
#if !defined(__ASSEMBLER__)
#include <oqs/rand.h>
#include <stdint.h>
#include "sys.h"
static MLK_INLINE int mlk_randombytes(uint8_t *ptr, size_t len)
{
    OQS_randombytes(ptr, len);
    return 0;
}
#endif

// No native assembly backends -- use portable C
// #define MLK_CONFIG_USE_NATIVE_BACKEND_ARITH
// #define MLK_CONFIG_USE_NATIVE_BACKEND_FIPS202
// #define MLK_CONFIG_NO_ASM  // Keep inline asm for value barriers

#endif // MLK_MLKEM_NATIVE_CONFIG_H
