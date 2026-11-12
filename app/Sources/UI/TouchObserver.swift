// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// Sees every touch that reaches the window and takes none of them: it never recognises anything, never cancels or delays a touch, and lets every other recogniser and view
/// work as if it was not there. The on-screen controls' idle timer uses it, because the controls and the game surface each see only their own touches.
final class TouchObserver: UIGestureRecognizer {
    /// Called on every touch event with how many fingers are down now.
    var onChange: ((Int) -> Void)?
    private var down = Set<UITouch>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { down.formUnion(touches); onChange?(down.count) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { onChange?(down.count) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { down.subtract(touches); onChange?(down.count) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { down.subtract(touches); onChange?(down.count) }
    override func reset() { down.removeAll() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
