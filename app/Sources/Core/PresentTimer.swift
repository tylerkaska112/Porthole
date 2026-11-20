// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import Metal
import ObjectiveC
import QuartzCore

/// Watches the pictures the game puts on the screen: for each one, when the game asked a Metal layer for it and when it was on the screen (PresentTimingTracker turns that into the game's frame
/// time and the delay after the game presents, which is where frame queues and frame generation cost time). It works from this side of the engine: while a number that needs it is on the
/// performance overlay, `-[CAMetalLayer nextDrawable]` is wrapped to note the time and to ask to be told when the picture is shown. Off, it is not wrapped and costs nothing.
///
/// Which layer is the game's differs: in a plain session it is the app's own game layer, in a desktop session (Steam games, `MADEIRA_DESKTOP`) it is a layer Wine makes for its desktop window, and
/// the launcher's hidden browser window has one too (about ten pictures a second). So every layer of a useful size is watched, and the numbers come from the one asked for most often.
final class PresentTimer: @unchecked Sendable {
    static let shared = PresentTimer()
    private let lock = NSLock()
    private struct Watch { var tracker = PresentTimingTracker(); var asks: [Double] = []; var lastAsk = 0.0 }
    private var watches: [ObjectIdentifier: Watch] = [:]
    private var counter: UInt64 = 0
    private var original: IMP?
    private var startedAt = 0.0
    private var reportedLayers = Set<ObjectIdentifier>()
    private static let selector = NSSelectorFromString("nextDrawable")
    /// Layers smaller than this are helper windows, not the game.
    private static let smallest = CGSize(width: 640, height: 360)

    /// Starts watching the layers' pictures.
    func start() {
        lock.lock()
        let already = original != nil
        if !already { startedAt = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
        guard !already else { return }
        install()
        LogStore.shared.log("[latency] watching the pictures the game asks the screen for")
    }

    func stop() {
        uninstall()
        lock.lock(); watches = [:]; reportedLayers = []; lock.unlock()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return original != nil }

    /// The game's own frame time and the time from asking for a picture to seeing it, in milliseconds (the middle of the recent frames); nil while nothing recent is known.
    /// `picturesPerFrame`: how many pictures a game frame is (1, or 2 or more while frame generation is making extra ones).
    func frameMs(picturesPerFrame: Int = 1) -> Double? { dominant { $0.frameMs(now: $1, picturesPerFrame: picturesPerFrame) } }
    func screenMs(picturesPerFrame: Int = 1) -> Double? { dominant { $0.screenMs(now: $1, picturesPerFrame: picturesPerFrame) } }

    /// Reads a number from the layer the most pictures were asked of in the last two seconds.
    private func dominant(_ read: (PresentTimingTracker, Double) -> Double?) -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        var best: (key: ObjectIdentifier, count: Int)?
        for (key, w) in watches {
            let count = w.asks.filter { now - $0 <= 2 }.count
            if count > (best?.count ?? 0) { best = (key, count) }
        }
        return best.flatMap { watches[$0.key] }.flatMap { read($0.tracker, now) }
    }

    private func install() {
        guard let method = class_getInstanceMethod(CAMetalLayer.self, Self.selector) else {
            LogStore.shared.log("[latency] cannot watch the pictures: CAMetalLayer has no nextDrawable")
            return
        }
        lock.lock()
        guard original == nil else { lock.unlock(); return }
        let orig = method_getImplementation(method)
        original = orig
        lock.unlock()
        typealias Next = @convention(c) (AnyObject, Selector) -> AnyObject?
        let call = unsafeBitCast(orig, to: Next.self)
        let sel = Self.selector
        let block: @convention(block) (AnyObject) -> AnyObject? = { [weak self] receiver in
            // The time is taken BEFORE the call: it waits when the layer has no free drawable (the screen has not let go of one yet), and that wait is part of the delay.
            let before = ProcessInfo.processInfo.systemUptime
            let drawable = call(receiver, sel)
            if let self, let drawable { self.asked(drawable, from: receiver, at: before) }
            return drawable
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private func uninstall() {
        lock.lock()
        let orig = original
        original = nil
        lock.unlock()
        guard let orig, let method = class_getInstanceMethod(CAMetalLayer.self, Self.selector) else { return }
        method_setImplementation(method, orig)
    }

    private func asked(_ drawable: AnyObject, from receiver: AnyObject, at now: Double) {
        guard let d = drawable as? MTLDrawable, let layer = receiver as? CAMetalLayer else { return }
        let size = layer.drawableSize
        guard size.width >= Self.smallest.width, size.height >= Self.smallest.height else { return }
        let key = ObjectIdentifier(layer)
        lock.lock()
        guard original != nil else { lock.unlock(); return }
        counter &+= 1
        let id = counter
        var w = watches[key] ?? Watch()
        w.tracker.asked(id, at: now)
        w.asks.append(now); w.lastAsk = now
        if w.asks.count > 240 { w.asks.removeFirst(w.asks.count - 240) }
        watches[key] = w
        if watches.count > 6 { for (k, v) in watches where now - v.lastAsk > 5 { watches[k] = nil } }          // layers that went away
        let first = reportedLayers.insert(key).inserted, seen = reportedLayers.count
        lock.unlock()
        if first { LogStore.shared.log(String(format: "[latency] a layer of %.0fx%.0f is being drawn to (%d layer(s) seen so far)", size.width, size.height, seen)) }
        d.addPresentedHandler { [weak self] _ in
            let t = ProcessInfo.processInfo.systemUptime
            guard let self else { return }
            self.lock.lock(); self.watches[key]?.tracker.shown(id, at: t); self.lock.unlock()
        }
    }
}
