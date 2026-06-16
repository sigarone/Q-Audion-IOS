/* qaudion_crypto_core_stub.c — PLACEHOLDER fail-closed definitions of the v4 crypto-core C ABI.
 *
 * ───────────────────────────────────────────────────────────────────────────────────────────
 *  WHY THIS FILE EXISTS (read before deleting it)
 * ───────────────────────────────────────────────────────────────────────────────────────────
 *  The real implementation of these symbols lives in the Rust crypto core
 *  (sigarone/qaudion-crypto-core, src/ffi.rs), shipped to iOS as a precompiled
 *  `QaudionCryptoCore.xcframework` (built by that repo's .github/workflows/ios.yml — Stage A).
 *
 *  As of this commit the XCFramework exists ONLY as a CI artifact; it has not been published to a
 *  stable URL with a pinned SwiftPM checksum, so it cannot yet be added as a SwiftPM
 *  `.binaryTarget(url:checksum:)` (SwiftPM requires the zip to be downloadable at resolve time).
 *  Without a definition of these symbols the test executable would fail to LINK on CI.
 *
 *  So this stub provides minimal, FAIL-CLOSED C definitions of the exact ABI declared in
 *  qaudion_crypto_core.h. Its only jobs are:
 *    1. let `RatchetNative.swift` compile + type-check against the REAL header (genuine surface
 *       verification, not dead #if-stubbed code), and
 *    2. let `swift build` / `swift test` LINK and stay green on the engine-tests.yml CI.
 *
 *  It deliberately performs NO cryptography and creates NO sessions. Every function returns its
 *  fail-closed value (an error QaStatus / NULL handle / version 0). This is the same fail-closed
 *  posture the real C ABI uses, so even in the (default-OFF) v4 path nothing here can fabricate a
 *  ratchet, a key, or a plaintext. `MessageRatchet.v4NativeRatchetEnabled` is `false`, so the live
 *  app never calls these anyway.
 *
 *  ⇒ TO ACTIVATE THE REAL CORE: replace this whole `CQaudionCryptoCore` C target in Package.swift
 *    with a `.binaryTarget` pointing at the published QaudionCryptoCore.xcframework (URL + the
 *    `swift package compute-checksum` value printed by the crypto-core ios.yml run), then delete
 *    this stub and the committed header copy (the XCFramework carries its own header + modulemap).
 *    See the "PHASE-3 INTEGRATION" comment block in Package.swift.
 * ───────────────────────────────────────────────────────────────────────────────────────────
 */

#include "qaudion_crypto_core.h"

QaStatus qa_session_init(const uint8_t *root_0,
                         const uint8_t *first_ss_xwing,
                         const uint8_t *transcript_hash,
                         int32_t is_a,
                         QaSession **out_session) {
    (void)root_0; (void)first_ss_xwing; (void)transcript_hash; (void)is_a;
    if (out_session) { *out_session = NULL; }
    return QA_STATUS_NULL_ARG; /* fail-closed: no session created by the stub */
}

QaStatus qa_root_0(const uint8_t *ss_handshake, uint8_t *out_root0) {
    (void)ss_handshake; (void)out_root0;
    return QA_STATUS_NULL_ARG; /* fail-closed: no key derived by the stub */
}

QaStatus qa_ratchet_encrypt(QaSession *session,
                            const uint8_t *plaintext,
                            uintptr_t plaintext_len,
                            uint8_t *out,
                            uintptr_t *out_len) {
    (void)session; (void)plaintext; (void)plaintext_len; (void)out;
    if (out_len) { *out_len = 0; }
    return QA_STATUS_NULL_ARG; /* fail-closed: no ciphertext produced by the stub */
}

QaStatus qa_ratchet_decrypt(QaSession *session,
                            const uint8_t *frame,
                            uintptr_t frame_len,
                            uint8_t *out,
                            uintptr_t *out_len) {
    (void)session; (void)frame; (void)frame_len; (void)out;
    if (out_len) { *out_len = 0; }
    return QA_STATUS_PARSE_ERROR; /* fail-closed: no plaintext recovered by the stub */
}

QaStatus qa_dh_ratchet(QaSession *session,
                       const uint8_t *ss_xwing,
                       const uint8_t *transcript_hash) {
    (void)session; (void)ss_xwing; (void)transcript_hash;
    return QA_STATUS_NULL_ARG; /* fail-closed: no epoch advance by the stub */
}

QaStatus qa_session_serialize(const QaSession *session, uint8_t *out, uintptr_t *out_len) {
    (void)session; (void)out;
    if (out_len) { *out_len = 0; }
    return QA_STATUS_NULL_ARG; /* fail-closed: nothing serialized by the stub */
}

QaStatus qa_session_deserialize(const uint8_t *data, uintptr_t data_len, QaSession **out_session) {
    (void)data; (void)data_len;
    if (out_session) { *out_session = NULL; }
    return QA_STATUS_PARSE_ERROR; /* fail-closed: no session restored by the stub */
}

void qa_session_free(QaSession *session) {
    (void)session; /* the stub never hands out a non-NULL handle, so nothing to free */
}

uint32_t qa_version(void) {
    return 0u; /* 0 == "stub / no real core linked"; the real core returns 0x00010000 (0.1.0) */
}
