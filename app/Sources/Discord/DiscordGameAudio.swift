// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The game's own sound for Go Live: what the game sent to the engine's audio unit (patch 0201 copies it into a ring after the game's volume and before Discord's voice is
/// added, so the call's voices are not in it), as 20 ms Opus packets, stereo at 48 kHz, at music quality. The ring is read on the stream's timer; when nothing has arrived or the
/// game is silent there is no packet and the caller sends Opus silence.
final class DiscordGameAudio {
    private var encoder: OpaquePointer?
    private var source: [Float] = []        // interleaved stereo at the engine's rate, waiting to be cut into 20 ms
    private var phase = 0.0                 // fraction of a source frame already used (the rate is resampled linearly to 48 kHz)
    private var rate = 48000.0
    private var scratch = [Float](repeating: 0, count: 4096 * 2)
    private(set) var packets = 0

    init?() {
        var err: Int32 = 0
        guard let e = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err), err == 0 else { return nil }
        encoder = e
        _ = porthole_opus_configure_encoder(e, 128_000)
    }

    deinit { if let encoder { opus_encoder_destroy(encoder) } }

    func start() {
        rate = Double(porthole_voice_rate())
        source.removeAll(keepingCapacity: true); phase = 0; packets = 0
        porthole_game_audio_start()
    }

    func stop() { porthole_game_audio_stop() }

    /// The next 20 ms of the game's sound as an Opus packet, or nil: not enough sound has arrived yet, or it is silent.
    func nextPacket() -> Data? {
        guard let encoder else { return nil }
        while true {      // everything the engine has put in the ring since the last time
            let n = scratch.withUnsafeMutableBufferPointer { porthole_game_audio_read($0.baseAddress, 4096) }
            if n == 0 { break }
            source.append(contentsOf: scratch[0..<(n * 2)])
            if n < 4096 { break }
        }
        let ratio = rate / 48000
        let need = Int((960 * ratio).rounded(.up)) + 2
        var frames = source.count / 2
        // A game that fell behind or a pause: keep the latest 120 ms, not a backlog.
        let keep = Int(rate * 0.12)
        if frames > keep + need { source.removeFirst((frames - keep) * 2); frames = keep; phase = 0 }
        guard frames >= need else { return nil }
        var out = [Float](repeating: 0, count: 960 * 2)
        var peak: Float = 0
        for i in 0..<960 {
            let p = phase + Double(i) * ratio
            let i0 = Int(p), t = Float(p - Double(i0))
            for c in 0..<2 {
                let v = source[2 * i0 + c] * (1 - t) + source[2 * (i0 + 1) + c] * t
                out[2 * i + c] = v
                peak = max(peak, abs(v))
            }
        }
        let used = phase + 960 * ratio
        let consumed = Int(used)
        phase = used - Double(consumed)
        source.removeFirst(consumed * 2)
        guard peak > 0.0003 else { return nil }      // silence: the caller sends Opus silence, which is also what Discord does
        var packet = [UInt8](repeating: 0, count: 1275)
        let size = opus_encode_float(encoder, out, 960, &packet, 1275)
        guard size > 0 else { return nil }
        packets += 1
        return Data(packet[0..<Int(size)])
    }
}
