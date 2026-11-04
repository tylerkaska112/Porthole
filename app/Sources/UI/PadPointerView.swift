// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// The game's own cursor, drawn where the engine says it is, while a controller's stick drives the mouse. A game running directly has no cursor on screen, so the
/// stick was invisible. The engine reports Wine's real cursor position, the image the game gave it and whether the game hides it (`winios_direct_cursor_*`), which
/// is exact where counting the stick's movement was not (it drifted: the game's pointer moved further than the stick's counts). Hidden while the game hides its cursor
/// (a first-person view) and in desktop sessions (the compositor draws it there). The Engine option "Pointer for the controller" can hide it when idle or switch it off.
/// Never takes touches.
final class PadPointerView: UIView {
    /// Desktop pixels -> a point in this view (the owner knows how the game is fitted on screen), the game's screen size, and the size of a desktop pixel in points.
    var viewPoint: ((Double, Double) -> CGPoint?)?
    var desktopSize: (() -> (Double, Double))?
    private let icon = UIImageView()
    private var link: CADisplayLink?
    private var mode = "", modeChecked: CFAbsoluteTime = 0, nudge: CGFloat = 0, logged = 0
    private var serial: UInt32 = 0
    private var cursorImage = winios_direct_cursor_state()
    private var buffer = [UInt8](repeating: 0, count: Int(WINIOS_CURSOR_MAX) * Int(WINIOS_CURSOR_MAX) * 4)
    private static var enabled = false
    /// Turns the driver's cursor reports on (it does nothing at all until then). Called when a game is about to start so the game's first cursor image is not missed.
    static func enableReports() {
        guard !enabled else { return }
        enabled = true
        // The view reads the state on its own clock; a hardware mouse (HardwareInput) wants to hear about every change, and there is one notify for both.
        winios_direct_cursor_enable { DispatchQueue.main.async { HardwareInput.shared.directCursorChanged() } }
        winios_direct_cursor_track(1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear
        icon.contentMode = .scaleToFill; icon.isHidden = true
        icon.layer.magnificationFilter = .nearest
        icon.image = Self.fallbackArrow()
        icon.frame = CGRect(x: 0, y: 0, width: 20, height: 30)
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        Self.enableReports()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        l.add(to: .main, forMode: .common); link = l
    }

    @objc private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - modeChecked > 1 { modeChecked = now; mode = EngineOptions.value("env.PORTHOLE_PAD_POINTER"); nudge = CGFloat(Double(EngineOptions.value("env.PORTHOLE_PAD_POINTER_UP")) ?? 0) }
        if let size = desktopSize?() { PadPointer.shared.setSize(width: size.0, height: size.1) }
        let use = PadPointer.shared.usage()
        guard mode != "0", use.used, !PadPointer.desktopSession else { icon.isHidden = true; link?.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 5, preferred: 4); return }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        var state = winios_direct_cursor_state()
        winios_direct_cursor_get(&state)
        // Wine's cursor, as the driver reports it. A program that never said anything about its cursor is shown one (Windows shows it by default).
        guard state.reports > 0, state.shown != 0 || state.image_serial == 0, let size = desktopSize?(), let p = viewPoint?(Double(state.x), Double(state.y)) else { icon.isHidden = true; return }
        if let corner = viewPoint?(size.0, 0), let origin = viewPoint?(0, 0), size.0 > 0 { scale = max(0.1, (corner.x - origin.x) / CGFloat(size.0)) }
        if state.image_serial != serial { loadImage() }
        let hideAfter: TimeInterval = mode == "autohide" ? 3 : .infinity
        icon.isHidden = false
        icon.alpha = use.idle < hideAfter ? 1 : max(0, 1 - (use.idle - hideAfter) / 0.6)
        let hasImage = serial != 0
        let w = hasImage ? CGFloat(cursorImage.w) : 14, h = hasImage ? CGFloat(cursorImage.h) : 21
        let hx = hasImage ? CGFloat(cursorImage.hot_x) : 0, hy = hasImage ? CGFloat(cursorImage.hot_y) : 0
        // The game's cursor at its own size on the game's screen, but never smaller than something you can see on a high-resolution game.
        let k = max(scale, 24 / max(w, h))
        icon.frame = CGRect(x: p.x - hx * k, y: p.y - hy * k - nudge, width: w * k, height: h * k)
        // A few lines in the log of what the arrow was placed from, in case it is off: the engine's cursor, the game's screen, the image and its hotspot.
        if logged < 6, state.x != 0 || state.y != 0, Int(now) % 2 == 0, now - lastLog > 1.5 {
            lastLog = now; logged += 1
            LogStore.shared.log("[pad-pointer] wine cursor (\(state.x), \(state.y)) screen \(Int(size.0))x\(Int(size.1)) -> view (\(Int(p.x)), \(Int(p.y))) image \(Int(w))x\(Int(h)) hotspot (\(Int(hx)), \(Int(hy))) draw scale \(String(format: "%.2f", k)) nudge \(Int(nudge))")
        }
    }
    private var scale: CGFloat = 1, lastLog: CFAbsoluteTime = 0

    private func loadImage() {
        let s = buffer.withUnsafeMutableBytes { raw in winios_direct_cursor_copy_image(raw.baseAddress, raw.count, &cursorImage) }
        guard s != 0, s != serial else { return }
        serial = s
        let w = Int(cursorImage.w), h = Int(cursorImage.h)
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue)
        guard w > 0, h > 0, let provider = CGDataProvider(data: Data(buffer[0..<(w * h * 4)]) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { serial = 0; return }
        icon.image = UIImage(cgImage: cg)
    }

    /// Until the game's own cursor image arrives: a plain arrow.
    private static func fallbackArrow() -> UIImage? {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 21)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 0.5, y: 0.5)); p.addLine(to: CGPoint(x: 0.5, y: 15.5)); p.addLine(to: CGPoint(x: 4.2, y: 12.2)); p.addLine(to: CGPoint(x: 7.0, y: 19.0))
            p.addLine(to: CGPoint(x: 9.6, y: 17.8)); p.addLine(to: CGPoint(x: 6.8, y: 11.1)); p.addLine(to: CGPoint(x: 11.8, y: 10.7)); p.close()
            UIColor.white.setFill(); p.fill(); UIColor.black.setStroke(); p.lineWidth = 1; p.stroke()
        }
    }
}
