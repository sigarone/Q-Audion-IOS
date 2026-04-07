#ifndef OPUS_H
#define OPUS_H

#include <stdint.h>

// Opus application types
#define OPUS_APPLICATION_VOIP 2048
#define OPUS_APPLICATION_AUDIO 2049

// Opus CTL request codes
#define OPUS_SET_BITRATE_REQUEST 4002
#define OPUS_SET_VBR_REQUEST 4006
#define OPUS_SET_COMPLEXITY_REQUEST 4010
#define OPUS_SET_SIGNAL_REQUEST 4024

// Error codes
#define OPUS_OK 0
#define OPUS_BAD_ARG -1
#define OPUS_INTERNAL_ERROR -3

// Opaque encoder/decoder types
typedef struct OpusEncoder OpusEncoder;
typedef struct OpusDecoder OpusDecoder;

// Encoder API
OpusEncoder *opus_encoder_create(int32_t Fs, int channels, int application, int *error);
int opus_encode(OpusEncoder *st, const int16_t *pcm, int frame_size, unsigned char *data, int32_t max_data_bytes);
int opus_encoder_ctl(OpusEncoder *st, int request, ...);
void opus_encoder_destroy(OpusEncoder *st);

// Decoder API
OpusDecoder *opus_decoder_create(int32_t Fs, int channels, int *error);
int opus_decode(OpusDecoder *st, const unsigned char *data, int32_t len, int16_t *pcm, int frame_size, int decode_fec);
void opus_decoder_destroy(OpusDecoder *st);

#endif // OPUS_H
