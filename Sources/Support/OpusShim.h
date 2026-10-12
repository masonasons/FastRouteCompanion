//
//  OpusShim.h
//  FastRoute Companion
//
//  opus_encoder_ctl is variadic, and Swift cannot call variadic C functions,
//  so this wraps the integer-valued requests the app uses.
//

#ifndef OpusShim_h
#define OpusShim_h

#include <opus/opus.h>

static inline int opus_encoder_ctl_set_int(OpusEncoder *enc, int request, opus_int32 value) {
    return opus_encoder_ctl(enc, request, value);
}

static inline int opus_decoder_ctl_set_int(OpusDecoder *dec, int request, opus_int32 value) {
    return opus_decoder_ctl(dec, request, value);
}

#endif /* OpusShim_h */
