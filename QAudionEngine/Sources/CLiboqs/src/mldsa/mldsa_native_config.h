/* SPDX-License-Identifier: Apache-2.0 OR ISC OR MIT */
/*
 * Q-Audion iOS: configuration of the vendored mldsa-native (v2.0.0) for ML-DSA-87.
 *
 * Replaces the upstream mldsa_native_config.h. Choices:
 *  - one parameter set (87) and the single-compilation-unit build (mldsa_native.c);
 *  - only the core entry points keypair_internal, signature_internal and verify_internal: the caller
 *    supplies the seed and the signing randomness, so this file needs no random number generator;
 *  - the SHA-3 / SHAKE functions of the existing CLiboqs sources (no second Keccak copy), through
 *    mldsa_fips202_glue.h, used serially (the glue has no 4-way API);
 *  - portable C only: no native arithmetic or Keccak backend.
 */
#ifndef MLD_CONFIG_H
#define MLD_CONFIG_H

#define MLD_CONFIG_PARAMETER_SET 87

#define MLD_CONFIG_NAMESPACE_PREFIX qa_mldsa87

#define MLD_CONFIG_CORE_API_ONLY
#define MLD_CONFIG_NO_RANDOMIZED_API
#define MLD_CONFIG_SERIAL_FIPS202_ONLY

#if defined(MLD_BUILD_INTERNAL)
/* Resolved relative to mldsa/src/ (the directory of symmetric.h). */
#define MLD_CONFIG_FIPS202_CUSTOM_HEADER "../mldsa_fips202_glue.h"
#endif

#endif /* MLD_CONFIG_H */
