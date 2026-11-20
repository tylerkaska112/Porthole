// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// libopus' settings calls take a variable number of arguments, which Swift cannot call: these wrap the few Discord voice needs.
#pragma once
#include <opus/opus.h>

static inline int porthole_opus_configure_encoder(OpusEncoder *encoder, int bitrate) {
    opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(5));
    return 0;
}
