// SPDX-License-Identifier: MIT
// Q-Audion iOS: liboqs configuration for SPM (no CMake)
// This replaces the CMake-generated oqsconfig.h

#ifndef OQS_OQSCONFIG_H
#define OQS_OQSCONFIG_H

#define OQS_VERSION_TEXT "0.12.0-qaudion"

// Enable ML-KEM-1024 only (FIPS 203, NIST Level 5)
#define OQS_ENABLE_KEM_ml_kem_1024

// Algorithm name constant
#define OQS_KEM_alg_ml_kem_1024 "ML-KEM-1024"

// Platform: iOS/macOS (Apple)
#if defined(__APPLE__)
  #define OQS_HAVE_GETENTROPY
  #if defined(__aarch64__)
    // ARM64 native build for iOS devices
    // Do NOT set OQS_ENABLE_KEM_ml_kem_1024_aarch64 --
    // we use the portable C reference implementation for now.
    // NEON optimization can be enabled later.
  #endif
#endif

// No OpenSSL dependency -- standalone build
// #define OQS_USE_OPENSSL

// No CUDA/ICICLE
// #define OQS_USE_CUPQC
// #define OQS_USE_ICICLE

// No dist build (single-platform SPM target)
// #define OQS_DIST_BUILD

// Memory features
#if defined(__APPLE__)
  #define OQS_HAVE_POSIX_MEMALIGN
  #define OQS_HAVE_EXPLICIT_BZERO
#endif

// Disable pthreads for single-threaded KEM operations
// #define OQS_USE_PTHREADS

#endif // OQS_OQSCONFIG_H
