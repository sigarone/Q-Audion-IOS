// Q-Audion iOS: libopus configuration for SPM
// Replaces autoconf-generated config.h

#ifndef OPUS_CONFIG_H
#define OPUS_CONFIG_H

#define OPUS_BUILD 1

// Use floating-point implementation (better for iOS/Apple Silicon)
#define FLOAT_APPROX 1
#define FLOATING_POINT 1

// Package info
#define PACKAGE_VERSION "1.5.2-qaudion"

// Standard features available on Apple platforms
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_MEMORY_H 1
#define HAVE_STRINGS_H 1
#define HAVE_ALLOCA_H 1
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_LRINTF 1
#define HAVE_LRINT 1

// Use alloca for stack allocation
#define USE_ALLOCA 1

// Restrict keyword
#define OPUS_RESTRICT restrict

// Variable-length arrays
#define VAR_ARRAYS 1

// No custom modes (standard Opus only)
// #define CUSTOM_MODES 1

// No fixed-point (using float)
// #define FIXED_POINT 1

// ARM NEON intrinsics are disabled because vendored libopus does not
// include the arm/ source directory. Generic C fallback is used instead.
// To enable: vendor opus/celt/arm/ and opus/silk/arm/ directories and
// uncomment the defines below.
// #if defined(__aarch64__) && defined(__APPLE__)
// #define OPUS_ARM_ASM 1
// #define OPUS_ARM_NEON_INTR 1
// #define OPUS_HAVE_RTCD 0
// #endif

#endif // OPUS_CONFIG_H
