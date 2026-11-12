// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// Blender only: a slim column of round buttons on the left edge for moving the 3D view by touch.
///
///   Select / Orbit / Pan  what ONE finger does when it drags (a tap always clicks); two fingers always pan and pinch zooms, three fingers orbit (TouchGestureEngine)
///   Camera                numpad 0 (look through the scene camera)
///   Frame                 numpad . (frame what is selected)
///   All                   Home (frame everything)
///
/// It is added to the HUD only while the running program is Blender (GameHUDView.isBlender); no other program or game ever sees it.
final class BlenderNavBar: UIStackView {
    private(set) var mode: NavMode = .select { didSet { refresh() } }
    private var modeButtons: [NavMode: UIButton] = [:]

    private static func symbol(_ name: String) -> UIImage? { UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)) }

    private func round(_ symbolName: String, label: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(Self.symbol(symbolName), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 0, alpha: 0.55)
        b.layer.cornerRadius = 23
        b.accessibilityLabel = label
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 46).isActive = true
        b.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return b
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical; spacing = 8; alignment = .center
        for (m, name, label) in [(NavMode.select, "cursorarrow", "Select: one finger clicks and drags"), (.orbit, "rotate.3d", "Orbit: one finger turns the view"),
                                 (.pan, "hand.draw", "Pan: one finger slides the view")] {
            let b = round(name, label: label)
            b.addAction(UIAction { [weak self] _ in self?.mode = m }, for: .touchUpInside)
            modeButtons[m] = b
            addArrangedSubview(b)
        }
        let gap = UIView(); gap.translatesAutoresizingMaskIntoConstraints = false; gap.heightAnchor.constraint(equalToConstant: 6).isActive = true
        addArrangedSubview(gap)
        for (name, label, vk) in [("video", "Camera view", Int32(0x60)), ("viewfinder", "Frame the selection", Int32(0x6E)), ("arrow.up.left.and.arrow.down.right", "Frame everything", Int32(0x24))] {
            let b = round(name, label: label)
            b.addAction(UIAction { _ in HUDKeys.tap(vk) }, for: .touchUpInside)
            addArrangedSubview(b)
        }
        refresh()
    }
    required init(coder: NSCoder) { fatalError() }

    private func refresh() {
        for (m, b) in modeButtons { b.backgroundColor = m == mode ? UIColor.systemBlue.withAlphaComponent(0.85) : UIColor(white: 0, alpha: 0.55) }
    }

    /// Back to the plain mouse (a new session).
    func reset() { mode = .select }
}
