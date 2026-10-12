//
//  Codecs-Bridging-Header.h
//  FastRoute Companion
//
//  Exposes libopus and libFLAC (installed by Homebrew) to Swift. The build
//  copies the dylibs into the app bundle, see Scripts/bundle-libs.sh.
//

#ifndef Codecs_Bridging_Header_h
#define Codecs_Bridging_Header_h

#include <opus/opus.h>
#include <FLAC/stream_encoder.h>
#include <FLAC/stream_decoder.h>
#include "OpusShim.h"

#endif /* Codecs_Bridging_Header_h */
