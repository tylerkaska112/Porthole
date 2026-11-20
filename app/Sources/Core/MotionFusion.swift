// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import simd

/// A controller's orientation from its motion sensors, for the 3D controller in Settings > Controls > Test controller. Some pads give GameController an attitude; a DualSense gives only how fast it
/// is turning (the gyro) and which way is down (gravity), so the orientation is worked out here: the turning is added up, and gravity keeps it from drifting off level. Nothing tells which way is
/// north, so the heading (yaw) slowly wanders and is put back by "Centre". Foundation and simd only, so a host test can check it.
///
/// The frame is GameController's: x to the right, y away from the player, z out of the face, the same as the 3D model's, so the result turns the model directly.
struct MotionFusion {
    /// The pad's orientation: rotates the pad's own axes into the room's (z up).
    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var started = false

    /// How hard gravity pulls the orientation back to level, per second. Higher follows the sensor faster and shakes more.
    var levelling: Float = 1.5

    /// The room's "down".
    private static let down = SIMD3<Float>(0, 0, -1)

    /// `rate` is the turning in radians a second about the pad's own axes (nil if the pad has no gyro); `gravity` is which way is down in the pad's own axes (nil if none; a unit vector, or any
    /// length). `dt` is the seconds since the last call.
    mutating func update(rate: SIMD3<Float>?, gravity: SIMD3<Float>?, dt: Float) {
        guard dt > 0, dt < 0.5 else { return }
        if !started {
            // The first look: level to where gravity says, with the heading as it is.
            if let g = Self.unit(gravity) {
                orientation = simd_quatf(from: g, to: Self.down)
                started = true
            } else if rate != nil { started = true }
            return
        }
        if let w = rate, w.x.isFinite, w.y.isFinite, w.z.isFinite {
            let angle = simd_length(w) * dt
            if angle > 1e-6 { orientation = orientation * simd_quatf(angle: angle, axis: simd_normalize(w)) }
        }
        if let g = Self.unit(gravity) {
            // Where the pad expects down to be, against where it is: turn the orientation by the small difference.
            let predicted = orientation.inverse.act(Self.down)
            let error = simd_cross(predicted, g)
            let angle = simd_length(error)
            if angle > 1e-6 { orientation = orientation * simd_quatf(angle: -min(angle * levelling * dt, angle), axis: error / angle) }
        }
        orientation = simd_normalize(orientation)
    }

    mutating func reset() { orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1); started = false }

    private static func unit(_ v: SIMD3<Float>?) -> SIMD3<Float>? {
        guard let v, v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
        let l = simd_length(v)
        return l > 0.2 ? v / l : nil
    }

    /// The heading part of an orientation: the turn about the room's vertical that the pad's front (its y axis) has made from straight ahead.
    static func heading(of q: simd_quatf) -> Float {
        let front = q.act(SIMD3<Float>(0, 1, 0))
        // The front points along y when the heading is zero; atan2 of how far it has swung to the left.
        return atan2(-front.x, front.y)
    }

    /// The orientation with its heading taken out, so "Centre" makes the pad face the player while keeping its real tilt.
    static func levelled(_ q: simd_quatf, heading h: Float) -> simd_quatf {
        simd_quatf(angle: -h, axis: SIMD3<Float>(0, 0, 1)) * q
    }
}
