// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

/// A mouse or trackpad on a scroll view. iPadOS lets the wheel and two-finger swipes scroll along the view's own axis only, and a click-and-drag does not scroll at all: a shelf of games
/// that runs sideways could not be scrolled by a mouse wheel (it turns vertically), and a long library was out of reach. Put `.background(PointerScroll())` inside a ScrollView:
/// * pressing and dragging with the pointer scrolls (the scroll view's own recognizer is told to take pointer touches);
/// * on a view that scrolls sideways only, the wheel's up-and-down turn scrolls it sideways, in the direction set under Settings > Engine options > Keyboard and mouse.
struct PointerScroll: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { PointerScrollAnchor() }
    func updateUIView(_ view: UIView, context: Context) {}
}

final class PointerScrollAnchor: UIView {
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var v: UIView? = superview
        while let current = v, !(current is UIScrollView) { v = current.superview }
        if let scroll = v as? UIScrollView { PointerScrollSupport.install(on: scroll) }
    }
}

/// +1 follows the system's own sense (iPadOS Settings > Trackpad & Mouse > Natural scrolling), -1 turns it around.
enum ScrollDirection {
    static var sign: CGFloat { CGFloat(InputSettings.shared.scrollSign) }
}

final class PointerScrollSupport: NSObject, UIGestureRecognizerDelegate {
    private static let key = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private weak var scroll: UIScrollView?

    static func install(on scroll: UIScrollView) {
        guard objc_getAssociatedObject(scroll, key) == nil else { return }
        let support = PointerScrollSupport()
        support.scroll = scroll
        objc_setAssociatedObject(scroll, key, support, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let pan = scroll.panGestureRecognizer
        pan.addTarget(support, action: #selector(observeScroll(_:)))
        if !pan.allowedTouchTypes.contains(pointer) { pan.allowedTouchTypes = pan.allowedTouchTypes + [pointer] }
        // The scroll view's own wheel and trackpad scrolling stays exactly as UIKit has it.
        pan.allowedScrollTypesMask = [.discrete, .continuous]
        let wheel = UIPanGestureRecognizer(target: support, action: #selector(wheel(_:)))
        wheel.allowedTouchTypes = []                                   // never a finger or a click: scroll events only
        wheel.allowedScrollTypesMask = [.discrete, .continuous]
        wheel.cancelsTouchesInView = false
        wheel.delegate = support
        scroll.addGestureRecognizer(wheel)
    }

    /// Only a view that runs sideways and does not run up and down needs this recognizer. On every other scroll view it must not even begin: two recognizers on one scroll view
    /// otherwise compete, and the wheel then no longer scrolls the screen (what 1.2.128 did to every vertical screen).
    static func sidewaysOnly(_ scroll: UIScrollView) -> Bool {
        let size = scroll.bounds.size, content = scroll.contentSize
        return content.width > size.width + 1 && content.height <= size.height + 1
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { scroll.map(Self.sidewaysOnly) ?? false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The scroll view's own recognizer, seen from the side: a turn of the wheel (no finger on the screen) moves it, in the direction the system's scrolling setting gives. HardwareInput
    /// compares that with the wheel pad's report of the same turn, so a game's wheel can turn the same way (ScrollSense).
    @objc private func observeScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed, g.numberOfTouches == 0, let scroll else { return }
        let dy = g.translation(in: scroll).y
        if dy != 0 { HardwareInput.shared.noteSystemScroll(dyPoints: Double(dy)) }
    }

    @objc private func wheel(_ g: UIPanGestureRecognizer) {
        guard let scroll else { return }
        let t = g.translation(in: scroll)
        g.setTranslation(.zero, in: scroll)
        let size = scroll.bounds.size, content = scroll.contentSize
        guard Self.sidewaysOnly(scroll), abs(t.y) >= abs(t.x) else { return }    // a sideways turn of the wheel is the scroll view's own
        var offset = scroll.contentOffset
        offset.x -= t.y * ScrollDirection.sign
        let lowest = -scroll.adjustedContentInset.left, highest = content.width - size.width + scroll.adjustedContentInset.right
        offset.x = min(max(offset.x, lowest), max(lowest, highest))
        scroll.setContentOffset(offset, animated: false)
    }
}

/// Every scroll view in the app takes a mouse: pressing and dragging scrolls it, the wheel scrolls it the way UIKit does, and a shelf that only runs sideways follows the wheel's
/// up-and-down turn. Done once for all of them (a screen added later is covered too) instead of screen by screen. Text views (dragging selects text) and web pages are left alone.
enum PointerScrollEverywhere {
    private static var done = false

    static func install() {
        guard !done else { return }
        done = true
        let original = #selector(UIView.didMoveToWindow), replacement = #selector(UIScrollView.porthole_didMoveToWindow)
        guard let originalMethod = class_getInstanceMethod(UIScrollView.self, original),
              let replacementMethod = class_getInstanceMethod(UIScrollView.self, replacement) else { return }
        // UIScrollView does not define didMoveToWindow itself (UIView does): give it its own copy first, so exchanging touches UIScrollView only and never every view.
        if class_addMethod(UIScrollView.self, original, method_getImplementation(replacementMethod), method_getTypeEncoding(replacementMethod)) {
            class_replaceMethod(UIScrollView.self, replacement, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }
}

extension UIScrollView {
    @objc fileprivate func porthole_didMoveToWindow() {
        porthole_didMoveToWindow()                       // the original (the implementations are exchanged)
        guard window != nil, !(self is UITextView), !NSStringFromClass(type(of: self)).contains("WK") else { return }
        PointerScrollSupport.install(on: self)
    }
}
