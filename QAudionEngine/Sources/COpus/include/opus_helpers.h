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

#endif /* OPUS_HELPERS_H */
