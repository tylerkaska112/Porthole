// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// A trackpad for the touch screen: a finger sliding anywhere moves a cursor (it does not jump to the finger), a tap clicks where the cursor is, and the usual laptop gestures work.
/// Point-and-click and strategy games, menus and anything with small targets are far easier this way than with a fingertip covering the target. Playport's "Point & click" layout has the
/// same idea; this is Porthole's own, with the same interface as TouchGestureEngine so the game surface can use either. Pure logic (no UIKit), so it can be tested with scripted touches.
///
///   one finger slides    -> the cursor moves (a little faster when the finger is fast)
///   tap                  -> click with the primary button, where the cursor is
///   tap, then touch again quickly and slide -> the primary button is held while the cursor moves (drag), released at lift
///   two-finger tap       -> click with the other button (right, normally)
///   two fingers slide up or down -> mouse wheel
final class TrackpadEngine {
    struct Config {
        var sensitivity: CGFloat = 1.0          // cursor travel per finger travel at a slow speed
        var acceleration: CGFloat = 0.8         // extra gain at a fast swipe (0 = none)
        var accelSpeed: CGFloat = 900           // finger speed, points a second, at which the extra gain is full
        var slop: CGFloat = 10                  // points a finger may wander and still be a tap
        var tapMax: TimeInterval = 0.28         // a tap is quicker than this
        var dragWindow: TimeInterval = 0.35     // touching again within this after a tap starts a drag
        var scrollStep: CGFloat = 24            // points of two-finger travel for one wheel notch
        var twoFingerTapMax: TimeInterval = 0.35
    }

    var config = Config()
    var primary: MouseButton = .left
    weak var sink: PointerSink?
    /// Fingers moving up scroll the page down (the content follows the fingers), as on a phone; false is the other way, as a mouse wheel.
    var naturalScroll = true
    /// Where the cursor may go: the game's picture.
    var bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    /// The cursor, in the surface's points. The surface sets it when a game starts and reads it to draw its arrow.
    var cursor = CGPoint(x: 500, y: 300)

    private var secondary: MouseButton { primary == .left ? .right : .left }
    private var points: [Int: CGPoint] = [:]
    private var lastTapEnd: TimeInterval = -.infinity

    private enum State {
        case idle
        case one(id: Int, start: CGPoint, last: CGPoint, lastTime: TimeInterval, began: TimeInterval, moved: Bool)
        case drag(id: Int, last: CGPoint, lastTime: TimeInterval)
        case two(a: Int, b: Int, began: TimeInterval, lastMidY: CGFloat, carried: CGFloat, scrolled: Bool)
        case waiting(remaining: Set<Int>)
    }
    private var state = State.idle

    var isTouching: Bool { if case .idle = state { return false }; return true }

    // MARK: Touch events

    func began(_ id: Int, at p: CGPoint, time: TimeInterval) {
        points[id] = p
        switch state {
        case .idle:
            if time - lastTapEnd <= config.dragWindow {
                lastTapEnd = -.infinity
                state = .drag(id: id, last: p, lastTime: time)
                sink?.pointerPress(primary, at: cursor)
            } else {
                state = .one(id: id, start: p, last: p, lastTime: time, began: time, moved: false)
            }
        case .one(let first, _, _, _, _, _):
            guard let a = points[first] else { return }
            state = .two(a: first, b: id, began: time, lastMidY: (a.y + p.y) / 2, carried: 0, scrolled: false)
        case .drag:
            break                                                   // a finger joining a drag changes nothing
        case .two(let a, let b, _, _, _, _):
            state = .waiting(remaining: [a, b, id])
        case .waiting(var remaining):
            remaining.insert(id); state = .waiting(remaining: remaining)
        }
    }

    func moved(_ id: Int, to p: CGPoint, time: TimeInterval) {
        points[id] = p
        switch state {
        case .one(let fid, let start, let last, let lastTime, let began, let wasMoved) where fid == id:
            slide(from: last, to: p, dt: time - lastTime)
            state = .one(id: id, start: start, last: p, lastTime: time, began: began, moved: wasMoved || hypot(p.x - start.x, p.y - start.y) > config.slop)
        case .drag(let fid, let last, let lastTime) where fid == id:
            slide(from: last, to: p, dt: time - lastTime)
            state = .drag(id: id, last: p, lastTime: time)
        case .two(let a, let b, let began, let lastMidY, let carried, let scrolled):
            guard id == a || id == b, let pa = points[a], let pb = points[b] else { return }
            let midY = (pa.y + pb.y) / 2
            var total = carried + (midY - lastMidY), didScroll = scrolled
            while abs(total) >= config.scrollStep {
                let up = total < 0                                   // the fingers went up
                let notch: Int32 = (up == naturalScroll) ? -120 : 120
                sink?.pointerWheel(notch, at: cursor)
                total += up ? config.scrollStep : -config.scrollStep
                didScroll = true
            }
            state = .two(a: a, b: b, began: began, lastMidY: midY, carried: total, scrolled: didScroll)
        default:
            break
        }
    }

    func ended(_ id: Int, at p: CGPoint, time: TimeInterval) {
        points[id] = nil
        switch state {
        case .one(let fid, _, _, _, let began, let moved) where fid == id:
            if !moved, time - began <= config.tapMax {
                sink?.pointerClick(primary, at: cursor)
                lastTapEnd = time
            }
            state = .idle
        case .drag(let fid, _, _) where fid == id:
            sink?.pointerRelease(primary, at: cursor)
            state = .idle
        case .two(let a, let b, let began, _, _, let scrolled):
            guard id == a || id == b else { return }
            if !scrolled, time - began <= config.twoFingerTapMax { sink?.pointerClick(secondary, at: cursor) }
            let other = id == a ? b : a
            state = points[other] == nil ? .idle : .waiting(remaining: [other])
        case .waiting(var remaining):
            remaining.remove(id)
            state = remaining.isEmpty ? .idle : .waiting(remaining: remaining)
        default:
            break
        }
        if case .idle = state { points.removeAll() }
    }

    func cancelled(_ id: Int) {
        points[id] = nil
        switch state {
        case .drag(let fid, _, _) where fid == id: sink?.pointerRelease(primary, at: cursor); state = .idle
        case .waiting(var remaining): remaining.remove(id); state = remaining.isEmpty ? .idle : .waiting(remaining: remaining)
        case .idle: break
        default: state = points.isEmpty ? .idle : .waiting(remaining: Set(points.keys))
        }
        if case .idle = state { points.removeAll() }
    }

    /// Nothing waits on time here (a tap is decided when the finger lifts); the surface still calls this on its timer.
    func tick(time: TimeInterval) {}

    // MARK: The cursor

    /// The cursor moves by the finger's travel times the gain, which grows with the finger's speed; it stays on the picture.
    private func slide(from a: CGPoint, to b: CGPoint, dt: TimeInterval) {
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx != 0 || dy != 0 else { return }
        let speed = dt > 0 ? hypot(dx, dy) / CGFloat(dt) : 0
        let gain = config.sensitivity * (1 + config.acceleration * min(speed / max(config.accelSpeed, 1), 1))
        cursor = CGPoint(x: min(max(cursor.x + dx * gain, bounds.minX), bounds.maxX), y: min(max(cursor.y + dy * gain, bounds.minY), bounds.maxY))
        sink?.pointerMove(cursor)
    }

    /// The pointer feel the settings offer: how fast the cursor goes.
    enum Speed: String, CaseIterable {
        case slow, normal, fast
        var title: String { switch self { case .slow: "Slow"; case .normal: "Normal"; case .fast: "Fast" } }
        var sensitivity: CGFloat { switch self { case .slow: 0.6; case .normal: 1.0; case .fast: 1.6 } }
    }
}

/// How touches reach the game: the finger is the cursor (a tap clicks under it), or the screen is a trackpad. Remembered for every game.
enum PointerMode: String, CaseIterable {
    case direct, trackpad
    static let key = "f4.pointerMode", speedKey = "f4.pointerSpeed"
    static var current: PointerMode { PointerMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .direct }
    static var speed: TrackpadEngine.Speed { TrackpadEngine.Speed(rawValue: UserDefaults.standard.string(forKey: speedKey) ?? "") ?? .normal }
    var title: String { switch self { case .direct: "Direct"; case .trackpad: "Trackpad" } }
    var detail: String {
        switch self {
        case .direct: "The finger is the cursor: a tap clicks under it, a drag drags."
        case .trackpad: "Slide anywhere to move the cursor, tap to click, tap and then drag to drag, two fingers tap for a right click or slide to scroll."
        }
    }
}
