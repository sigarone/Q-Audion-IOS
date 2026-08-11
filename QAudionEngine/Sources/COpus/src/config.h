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

// Deep PLC (FARGAN) — the neural concealment from Opus 1.5.
//
// 2026-08-11. Android has had this since `2312fa00`; iOS did not, and the
// difference is audible rather than theoretical. When a packet is missing the
// two platforms conceal it differently: Android synthesises plausible continuing
// speech, iOS falls back to classic libopus concealment, whose own comment in
// `AudioCapture` describes it decaying into audible ringing. A user on a real
// device called it "metallico" on the first long-profile call, and the long
// profile makes it worse in the obvious way — every concealment event lasts
// 60 ms instead of 20, so the worse method is also exposed three times longer.
//
// Compiled WITHOUT the SIMD kernels, unlike Android. This build defines no
// `OPUS_HAVE_RTCD` (see the block above — the whole codec is generic C here),
// so `nnet.c` dispatches straight to the C implementations in `nnet_default.c`
// and the `dnn/arm/` sources Android needs would have nothing to dispatch to.
// That also sidesteps the per-file `-march=armv8.2-a+dotprod` those kernels
// require, which SwiftPM cannot express — cSettings apply to a whole target.
//
// The C path is slower, and that is affordable HERE specifically: FARGAN runs
// only while concealing, not on every frame, so its duty cycle is the packet
// loss rate rather than 100%. If profiling ever says otherwise, the fix is a
// separate SwiftPM target for the dotprod kernel, not turning this off.
//
// Decoder-side only. Nothing changes on the wire and a peer without it is
// unaffected. Activation is NOT automatic: the model links in and never runs
// until `OPUS_SET_COMPLEXITY(5)` is set on the decoder — see `OpusCodec`, and
// see Android's `opus_jni.c:333` for the same call and the same warning.
#define ENABLE_DEEP_PLC 1

#endif // OPUS_CONFIG_H
