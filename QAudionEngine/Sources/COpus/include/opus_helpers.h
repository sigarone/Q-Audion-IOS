/*
 * opus_helpers.h
 *
 * Inline C wrappers for opus_encoder_ctl variadic calls.
 * Swift cannot call C variadic functions directly, so these
 * non-variadic wrappers bridge the gap.
 */

#ifndef OPUS_HELPERS_H
#define OPUS_HELPERS_H

#include "opus/opus.h"

static inline int opus_helper_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

static inline int opus_helper_set_complexity(OpusEncoder *enc, opus_int32 complexity) {
    return opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
}

static inline int opus_helper_set_signal(OpusEncoder *enc, opus_int32 signal) {
    return opus_encoder_ctl(enc, OPUS_SET_SIGNAL(signal));
}

static inline int opus_helper_set_vbr(OpusEncoder *enc, opus_int32 vbr) {
    return opus_encoder_ctl(enc, OPUS_SET_VBR(vbr));
}

static inline int opus_helper_set_inband_fec(OpusEncoder *enc, opus_int32 fec) {
    return opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(fec));
}

static inline int opus_helper_set_packet_loss_perc(OpusEncoder *enc, opus_int32 loss_perc) {
    return opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(loss_perc));
}

/* W528 — Android passes OPUS_SET_MAX_BANDWIDTH explicitly. iOS not
 * setting it lets libopus pick a narrower band at low bitrates,
 * which is audibly worse than Android's FULLBAND output. Constrain
 * iOS to the same wire shape so the decode side has matching
 * spectrum to reconstruct. */
static inline int opus_helper_set_max_bandwidth(OpusEncoder *enc, opus_int32 bandwidth) {
    return opus_encoder_ctl(enc, OPUS_SET_MAX_BANDWIDTH(bandwidth));
}

/* W537 — Android encoder sets OPUS_SET_LSB_DEPTH=16 explicitly. The
 * default is 24, which tells libopus the input PCM has bits below
 * 16 that are signal (not noise). Our capture is Int16 PCM so the
 * lower 8 bits below bit 16 are guaranteed to be noise; setting
 * LSB_DEPTH=16 lets the noise-shaped quantizer make better
 * trade-offs (don't spend bits encoding what is actually quantization
 * noise). User-perceived quality on Android receivers improves
 * because Opus reallocates the saved bits to the speech band. */
static inline int opus_helper_set_lsb_depth(OpusEncoder *enc, opus_int32 depth) {
    return opus_encoder_ctl(enc, OPUS_SET_LSB_DEPTH(depth));
}

/* W537 — Android also sets DTX explicitly to 0. Opus's default for
 * VOIP mode is also 0 but exposing the knob keeps parity with
 * `OpusConfig.dtx = false`. */
static inline int opus_helper_set_dtx(OpusEncoder *enc, opus_int32 dtx) {
    return opus_encoder_ctl(enc, OPUS_SET_DTX(dtx));
}

/* W-LONGAUDIO (2026-08-10) — pin the encoder's frame duration explicitly.
 *
 * libopus infers the frame duration from the `frame_size` argument passed to
 * `opus_encode`, and that inference is what sizes a CBR packet. Setting it
 * explicitly makes the operating point a stated fact rather than a derived
 * one, which matters the moment two frame durations exist in the fleet: a
 * mismatch between what we ask for and what we hand over stops being silent.
 *
 * Pass one of the OPUS_FRAMESIZE_* constants from opus_defines.h
 * (OPUS_FRAMESIZE_20_MS = 5004, OPUS_FRAMESIZE_60_MS = 5006). */
static inline int opus_helper_set_expert_frame_duration(OpusEncoder *enc,
                                                        opus_int32 frame_duration) {
    return opus_encoder_ctl(enc, OPUS_SET_EXPERT_FRAME_DURATION(frame_duration));
}

/* W-LONGAUDIO (2026-08-10) — the decoder's own record of how long the LAST
 * packet it decoded was, in samples per channel.
 *
 * This is the only correct input to packet-loss concealment. opus.h is
 * explicit that in the PLC case (`data == NULL`) `frame_size` is not buffer
 * capacity but "exactly the duration of audio that is missing"; concealing a
 * different duration than the stream carries walks the playout clock away
 * from the sender's with every concealed frame and no counter moves. Deriving
 * that duration from a negotiated profile would be wrong on an endpoint that
 * holds no negotiation state, and wrong again if the peer's frame duration
 * ever differs from what was negotiated. The decoder always knows.
 *
 * Writes samples-per-channel into *samples. Returns OPUS_OK (0) on success;
 * on any error *samples is left untouched, so the caller must initialise it. */
static inline int opus_helper_get_last_packet_duration(OpusDecoder *dec,
                                                       opus_int32 *samples) {
    return opus_decoder_ctl(dec, OPUS_GET_LAST_PACKET_DURATION(samples));
}

/* Turn on deep PLC (FARGAN), the neural concealment from Opus 1.5.
 *
 * This is a DECODER complexity, which reads like a performance knob and is not
 * one: at 5 the SILK decoder sets `DecControl.enable_deep_plc`, and below it the
 * FARGAN model is linked into the binary and never runs. That silent-no-op shape
 * is the one this codebase has been bitten by repeatedly — deep PLC itself
 * shipped inert on Android once — so the call belongs next to decoder creation
 * rather than in a caller's memory.
 *
 * 5 and not higher: 6 and 7 additionally request OSCE (LACE / NoLACE), which is
 * not compiled in this build. Mirrors Android `opus_jni.c:333` exactly, so the
 * two platforms conceal a lost packet the same way.
 *
 * Decoder-side only — nothing changes on the wire, and a peer without it is
 * unaffected. Returns OPUS_OK (0) on success; a failure is worth logging and not
 * worth failing a call over, since the classic concealment still works. */
static inline int opus_helper_enable_deep_plc(OpusDecoder *dec) {
    return opus_decoder_ctl(dec, OPUS_SET_COMPLEXITY(5));
}

#endif /* OPUS_HELPERS_H */
