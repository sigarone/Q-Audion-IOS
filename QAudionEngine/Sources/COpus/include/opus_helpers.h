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

#endif /* OPUS_HELPERS_H */
