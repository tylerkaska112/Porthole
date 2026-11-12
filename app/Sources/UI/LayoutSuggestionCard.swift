// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// The offer to switch to touch controls (LayoutSuggestion): a line of words and two buttons over the game, at the top. Only the buttons take touches; the rest of the card, like the
/// rest of the HUD, lets touches through to the game. It goes by itself after a while, which counts as "Not now".
final class LayoutSuggestionCard: UIView {
    var onSwitch: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var timer: Timer?

    init(text: String, lifetime: TimeInterval = 25) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(white: 0.06, alpha: 0.88)
        layer.cornerRadius = 16; layer.cornerCurve = .continuous
        layer.borderWidth = 1; layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 0

        func pill(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> UIButton {
            var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            config.title = title
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
            config.baseBackgroundColor = filled ? tintColor : UIColor(white: 1, alpha: 0.16)
            config.baseForegroundColor = .white
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
            return b
        }
        let switchButton = pill("Switch", filled: true) { [weak self] in self?.finish(switching: true) }
        let laterButton = pill("Not now", filled: false) { [weak self] in self?.finish(switching: false) }
        switchButton.accessibilityLabel = "Switch to touch controls"
        let buttons = UIStackView(arrangedSubviews: [laterButton, switchButton])
        buttons.axis = .horizontal; buttons.spacing = 10; buttons.distribution = .fillProportionally

        let stack = UIStackView(arrangedSubviews: [label, buttons])
        stack.axis = .vertical; stack.spacing = 10; stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in self?.finish(switching: false) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func finish(switching: Bool) {
        timer?.invalidate(); timer = nil
        let handler = switching ? onSwitch : onDismiss
        onSwitch = nil; onDismiss = nil
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
        handler?()
    }

    deinit { timer?.invalidate() }
}
