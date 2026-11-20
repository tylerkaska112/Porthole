// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Sliding a finger from one on-screen button to the next: the first lets go and the second goes down, without lifting (holding B to run, then sliding the thumb to A to jump).
/// Applies to the held buttons of the touch layouts and the on-screen keyboard; the gamepad's A B X Y and direction pad already follow the finger. Settings > Controls.
enum SlideAcross {
    static let key = "f4.slideAcross"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
