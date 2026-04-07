#include "opus.h"
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

// Stub implementation for CI builds
// Real libopus 1.5.2 sources replace this file

struct OpusEncoder {
    int32_t sample_rate;
    int channels;
    int application;
    int bitrate;
    int vbr;
};

struct OpusDecoder {
    int32_t sample_rate;
    int channels;
};

OpusEncoder *opus_encoder_create(int32_t Fs, int channels, int application, int *error) {
    OpusEncoder *enc = (OpusEncoder *)calloc(1, sizeof(OpusEncoder));
    if (!enc) { if (error) *error = OPUS_INTERNAL_ERROR; return NULL; }
    enc->sample_rate = Fs;
    enc->channels = channels;
    enc->application = application;
    enc->bitrate = 32000;
    enc->vbr = 0;
    if (error) *error = OPUS_OK;
    return enc;
}

int opus_encode(OpusEncoder *st, const int16_t *pcm, int frame_size, unsigned char *data, int32_t max_data_bytes) {
    (void)st;
    // Stub: copy first min(100, frame_size*2) bytes as "encoded" data
    int bytes = frame_size * 2;
    if (bytes > 100) bytes = 100;
    if (bytes > max_data_bytes) bytes = max_data_bytes;
    memcpy(data, pcm, bytes);
    return bytes;
}

int opus_encoder_ctl(OpusEncoder *st, int request, ...) {
    va_list args;
    va_start(args, request);
    switch (request) {
        case OPUS_SET_BITRATE_REQUEST:
            st->bitrate = va_arg(args, int);
            break;
        case OPUS_SET_VBR_REQUEST:
            st->vbr = va_arg(args, int);
            break;
        default:
            break;
    }
    va_end(args);
    return OPUS_OK;
}

void opus_encoder_destroy(OpusEncoder *st) { free(st); }

OpusDecoder *opus_decoder_create(int32_t Fs, int channels, int *error) {
    OpusDecoder *dec = (OpusDecoder *)calloc(1, sizeof(OpusDecoder));
    if (!dec) { if (error) *error = OPUS_INTERNAL_ERROR; return NULL; }
    dec->sample_rate = Fs;
    dec->channels = channels;
    if (error) *error = OPUS_OK;
    return dec;
}

int opus_decode(OpusDecoder *st, const unsigned char *data, int32_t len, int16_t *pcm, int frame_size, int decode_fec) {
    (void)st; (void)data; (void)len; (void)decode_fec;
    // Stub: return silence
    memset(pcm, 0, frame_size * sizeof(int16_t));
    return frame_size;
}

void opus_decoder_destroy(OpusDecoder *st) { free(st); }
