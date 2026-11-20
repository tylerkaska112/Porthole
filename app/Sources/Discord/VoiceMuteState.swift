// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// How "mute" and "deafen" belong together, the way Discord's own app does it: deafening also mutes the microphone, undoing the deafen puts the microphone back the way it was, and
/// unmuting the microphone while deafened undoes the deafen too (you cannot talk to a channel you do not hear).
struct VoiceMuteState: Equatable {
    /// The microphone sends nothing (also true while deafened).
    private(set) var micMuted = false
    /// The call is not played.
    private(set) var deafened = false
    private var micBeforeDeafen = false

    mutating func setMicMuted(_ on: Bool) {
        if deafened {
            if on { micBeforeDeafen = true; return }
            deafened = false
        }
        micMuted = on
    }

    mutating func setDeafened(_ on: Bool) {
        guard on != deafened else { return }
        if on { micBeforeDeafen = micMuted; micMuted = true; deafened = true }
        else { deafened = false; micMuted = micBeforeDeafen }
    }
}
