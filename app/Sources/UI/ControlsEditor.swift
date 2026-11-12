// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import UIKit

/// The editor for the on-screen controls, shown over the running game while the pencil is on. Everything is done on the screen itself, with no other menu:
///  * the tray at the bottom holds the controls you can add: drag one onto the screen (or tap it to put it in a free spot);
///  * drag a control to move it (it snaps to the middle and to the other controls), drag the dot on its corner or pinch to resize it;
///  * tap a control and its settings open beside it (what it does, press style, size, label, copy, delete), out of the way of the control itself;
///  * Undo and Redo, starting layouts and "Look" are in the bar at the top; Done goes back to playing.
/// It only draws the panels. The controls themselves are `CustomControlsView`, which saves every change.
final class ControlsEditorView: UIView {
    var onDone: (() -> Void)?
    private weak var controls: CustomControlsView?

    // The bar at the top.
    private let topBar = ControlsEditorPanel()
    private let doneButton = ControlsEditorView.chip("Done", prominent: true)
    private let undoButton = ControlsEditorView.chip("Undo"), redoButton = ControlsEditorView.chip("Redo")
    private let addButton = ControlsEditorView.chip("+ Add"), startButton = ControlsEditorView.chip("Presets \u{25BE}"), lookButton = ControlsEditorView.chip("Look off")
    private var trayOpen = false
    private let hint = UILabel()
    private var hintTimer: Timer?

    // The bottom panel: the tray when nothing is selected, the settings of the selected control otherwise.
    private let bottom = ControlsEditorPanel()
    private let tray = UIScrollView(), trayStack = UIStackView()
    private let settings = UIStackView()
    private let optionsButton = ControlsEditorView.chip("Options")
    private let doesButton = ControlsEditorView.chip("")
    private let latchButton = ControlsEditorView.chip("Latch: off")
    private let sizeSlider = UISlider(), sizeLabel = UILabel()
    private let labelButton = ControlsEditorView.chip("Label")
    private let copyButton = ControlsEditorView.chip("Copy"), deleteButton = ControlsEditorView.chip("Delete"), closeButton = ControlsEditorView.chip("\u{2715}")
    private var bottomAtBottom: NSLayoutConstraint!, bottomAtTop: NSLayoutConstraint!
    private var picker: KeyPickerView?
    private var ghost: UIView?
    private var selection: TouchControlSpec?

    /// What the tray offers (action id, face): the sticks, the mouse, and the keys most games use. "More" opens every key.
    private static let trayItems: [(action: String, face: String)] = [
        ("stick-wasd", "W A S D"), ("stick-arrows", "Arrows"),
        ("lmb", "LMB"), ("rmb", "RMB"), ("mmb", "MMB"), ("wheelup", "Wh\u{2191}"), ("wheeldown", "Wh\u{2193}"), ("lookmode", "Look/Mouse"), ("keyboard", "Keys"),
        ("space", "Space"), ("shift", "Shift"), ("ctrl", "Ctrl"), ("alt", "Alt"), ("key-E", "E"), ("key-F", "F"), ("key-R", "R"), ("key-Q", "Q"), ("key-C", "C"),
        ("key-V", "V"), ("key-G", "G"), ("key-X", "X"), ("key-Z", "Z"), ("tab", "Tab"), ("esc", "Esc"), ("enter", "Enter"),
        ("key-1", "1"), ("key-2", "2"), ("key-3", "3"), ("key-4", "4"), ("key-5", "5"), ("f1", "F1"), ("f5", "F5"),
        // The pad's controls, for a gamepad or a mix of pad and keys.
        ("stick-ls", "L stick"), ("stick-rs", "R stick"), ("dpad-pad", "D-pad"), ("pad-a", "A"), ("pad-b", "B"), ("pad-x", "X"), ("pad-y", "Y"),
        ("pad-lb", "LB"), ("pad-rb", "RB"), ("pad-lt", "LT"), ("pad-rt", "RT"), ("pad-start", "Menu"), ("pad-back", "View"),
    ]

    init(controls: CustomControlsView) {
        self.controls = controls
        super.init(frame: .zero)
        buildTopBar(); buildBottom(); wire()
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private static func chip(_ title: String, prominent: Bool = false) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(prominent ? .black : .white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.backgroundColor = prominent ? UIColor.systemYellow : UIColor(white: 1, alpha: 0.16)
        b.layer.cornerRadius = 15
        b.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    private func buildTopBar() {
        let row = UIStackView(arrangedSubviews: [doneButton, addButton, undoButton, redoButton, startButton, lookButton, optionsButton])
        row.axis = .horizontal; row.spacing = 6; row.alignment = .center
        topBar.contentView.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -8),
                                     row.topAnchor.constraint(equalTo: topBar.contentView.topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor, constant: -6)])
        topBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        hint.textColor = .white; hint.font = .systemFont(ofSize: 12, weight: .medium); hint.numberOfLines = 0; hint.textAlignment = .center
        hint.backgroundColor = UIColor(white: 0, alpha: 0.6); hint.layer.cornerRadius = 10; hint.layer.masksToBounds = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.text = "  Tap + Add, then tap a tile or hold it and drag it in \u{00B7} drag to move \u{00B7} drag the corner dot or pinch to resize \u{00B7} tap a control to change it  "
        addSubview(hint)
        NSLayoutConstraint.activate([topBar.centerXAnchor.constraint(equalTo: centerXAnchor), topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
                                     topBar.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
                                     topBar.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
                                     hint.centerXAnchor.constraint(equalTo: centerXAnchor), hint.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
                                     hint.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
                                     hint.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12)])
        startButton.showsMenuAsPrimaryAction = true
        optionsButton.showsMenuAsPrimaryAction = true
        startButton.menu = UIMenu(title: "Replace every control with\u{2026} (Undo brings them back)", children: [
            UIAction(title: "Mouse and keys layout") { [weak self] _ in self?.controls?.replaceLayout(.mouseAndKeys) },
            UIAction(title: "First person layout") { [weak self] _ in self?.controls?.replaceLayout(.firstPerson) },
            UIAction(title: "Gamepad layout") { [weak self] _ in self?.controls?.replaceLayout(.gamepad) },
            UIAction(title: "Empty screen", attributes: .destructive) { [weak self] _ in self?.controls?.replaceLayout(TouchLayout()) },
        ])
    }

    private func buildBottom() {
        bottom.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottom)
        bottomAtBottom = bottom.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8)
        bottomAtTop = bottom.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([bottomAtBottom, bottom.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     bottom.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
                                     bottom.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
                                     bottom.widthAnchor.constraint(lessThanOrEqualToConstant: 760)])
        let widthPreferred = bottom.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1, constant: -32); widthPreferred.priority = .defaultHigh; widthPreferred.isActive = true

        // The tray.
        tray.showsHorizontalScrollIndicator = false; tray.alwaysBounceHorizontal = true
        trayStack.axis = .horizontal; trayStack.spacing = 8; trayStack.alignment = .center
        for item in Self.trayItems { trayStack.addArrangedSubview(TrayTile(action: item.action, face: item.face, editor: self)) }
        trayStack.addArrangedSubview(TrayTile(action: "more", face: "More\u{2026}", editor: self))
        tray.addSubview(trayStack); trayStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([trayStack.leadingAnchor.constraint(equalTo: tray.contentLayoutGuide.leadingAnchor, constant: 10), trayStack.trailingAnchor.constraint(equalTo: tray.contentLayoutGuide.trailingAnchor, constant: -10),
                                     trayStack.topAnchor.constraint(equalTo: tray.contentLayoutGuide.topAnchor, constant: 8), trayStack.bottomAnchor.constraint(equalTo: tray.contentLayoutGuide.bottomAnchor, constant: -8),
                                     trayStack.heightAnchor.constraint(equalTo: tray.frameLayoutGuide.heightAnchor, constant: -16)])

        // The settings of the selected control.
        sizeSlider.minimumValue = Float(TouchLayout.sizeRange.lowerBound); sizeSlider.maximumValue = Float(TouchLayout.sizeRange.upperBound)
        sizeSlider.minimumTrackTintColor = .systemYellow; sizeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sizeLabel.textColor = .white; sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium); sizeLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        deleteButton.setTitleColor(.systemRed, for: .normal)
        let first = UIStackView(arrangedSubviews: [doesButton, labelButton, UIView(), copyButton, deleteButton, closeButton])
        first.axis = .horizontal; first.spacing = 8; first.alignment = .center
        let second = UIStackView(arrangedSubviews: [latchButton, Self.caption("Size"), sizeSlider, sizeLabel])
        second.axis = .horizontal; second.spacing = 8; second.alignment = .center
        settings.axis = .vertical; settings.spacing = 10; settings.addArrangedSubview(first); settings.addArrangedSubview(second)
        for v in [tray, settings] { v.translatesAutoresizingMaskIntoConstraints = false; bottom.contentView.addSubview(v) }
        NSLayoutConstraint.activate([tray.leadingAnchor.constraint(equalTo: bottom.contentView.leadingAnchor), tray.trailingAnchor.constraint(equalTo: bottom.contentView.trailingAnchor),
                                     tray.topAnchor.constraint(equalTo: bottom.contentView.topAnchor), tray.bottomAnchor.constraint(equalTo: bottom.contentView.bottomAnchor), tray.heightAnchor.constraint(equalToConstant: 86),
                                     settings.leadingAnchor.constraint(equalTo: bottom.contentView.leadingAnchor, constant: 12), settings.trailingAnchor.constraint(equalTo: bottom.contentView.trailingAnchor, constant: -12),
                                     settings.topAnchor.constraint(equalTo: bottom.contentView.topAnchor, constant: 10), settings.bottomAnchor.constraint(equalTo: bottom.contentView.bottomAnchor, constant: -10)])
        settings.isHidden = true
    }

    private static func caption(_ text: String) -> UILabel {
        let l = UILabel(); l.text = text; l.textColor = UIColor(white: 1, alpha: 0.75); l.font = .systemFont(ofSize: 13, weight: .medium); return l
    }

    private func wire() {
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        addButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.trayOpen = !(self.trayOpen && self.selection == nil)
            if self.selection != nil { self.trayOpen = true; self.controls?.select(nil) }      // from a control's settings: let go of it and show the tray
            self.dismissHint(); self.refresh()
        }, for: .touchUpInside)
        undoButton.addAction(UIAction { [weak self] _ in self?.controls?.undo(); self?.refresh() }, for: .touchUpInside)
        redoButton.addAction(UIAction { [weak self] _ in self?.controls?.redo(); self?.refresh() }, for: .touchUpInside)
        lookButton.addAction(UIAction { [weak self] _ in guard let c = self?.controls else { return }; c.setLook(!(c.layout?.look ?? false)); self?.refresh() }, for: .touchUpInside)
        copyButton.addAction(UIAction { [weak self] _ in self?.controls?.duplicateSelected() }, for: .touchUpInside)
        deleteButton.addAction(UIAction { [weak self] _ in self?.controls?.removeSelected() }, for: .touchUpInside)
        closeButton.addAction(UIAction { [weak self] _ in self?.controls?.select(nil) }, for: .touchUpInside)
        labelButton.addAction(UIAction { [weak self] _ in self?.askLabel() }, for: .touchUpInside)
        doesButton.addAction(UIAction { [weak self] _ in self?.chooseAction() }, for: .touchUpInside)
        // A key button already taps when tapped and holds when held; "latch" (each tap switches it on or off, for Shift or Ctrl) is the only choice left.
        latchButton.addAction(UIAction { [weak self] _ in
            self?.controls?.changeSelected { $0.mode = $0.mode == "latch" ? "tap" : "latch" }
        }, for: .touchUpInside)
        sizeSlider.addAction(UIAction { [weak self] _ in self?.sizeChanged(.changed) }, for: .valueChanged)
        sizeSlider.addAction(UIAction { [weak self] _ in self?.sizeChanged(.began) }, for: .touchDown)
        sizeSlider.addAction(UIAction { [weak self] _ in self?.sizeChanged(.ended) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    // MARK: State

    /// Starts or stops editing (this panel and the controls' editing state together).
    func setActive(_ on: Bool) {
        isHidden = !on
        controls?.editing = on
        guard on, let c = controls else { picker?.removeFromSuperview(); picker = nil; return }
        c.onSelect = { [weak self] spec in self?.selection = spec; self?.refresh() }
        c.onHistory = { [weak self] in self?.refresh() }
        c.onEdited = { [weak self] in self?.refreshValues() }
        selection = nil; trayOpen = false
        showHint()
        refresh()
    }

    private func showHint() {
        hint.isHidden = false; hint.alpha = 1
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 9, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.4) { self?.hint.alpha = 0 } completion: { _ in self?.hint.isHidden = true }
        }
    }

    private func dismissHint() { hintTimer?.invalidate(); if !hint.isHidden { UIView.animate(withDuration: 0.25) { self.hint.alpha = 0 } completion: { _ in self.hint.isHidden = true } } }

    /// The Options menu: how solid the controls are while playing, the tap on a press, and for the selected control its order (front or back) and a combo (Shift, Ctrl or Alt
    /// held with its key). Rebuilt on every refresh so its ticks show what is set.
    private func rebuildOptionsMenu() {
        guard let c = controls, let layout = c.layout else { return }
        let opacity = UIMenu(title: "Controls opacity when playing", children: [1.0, 0.8, 0.6, 0.4].map { value in
            UIAction(title: "\(Int(value * 100))%", state: abs(layout.opacity - value) < 0.05 ? .on : .off) { [weak self] _ in self?.controls?.setOpacity(value); self?.refresh() }
        })
        var children: [UIMenuElement] = [opacity,
            UIAction(title: "Tap feedback (haptics)", state: layout.haptics ? .on : .off) { [weak self] _ in self?.controls?.setHaptics(!layout.haptics); self?.refresh() },
            UIAction(title: "Lock positions and sizes", image: UIImage(systemName: layout.locked ? "lock.fill" : "lock.open"), state: layout.locked ? .on : .off) { [weak self] _ in self?.controls?.setLocked(!layout.locked); self?.refresh() }]
        if let sel = c.selectedSpec {
            var selected: [UIMenuElement] = [
                UIAction(title: "Bring to front", image: UIImage(systemName: "square.2.layers.3d.top.filled")) { [weak self] _ in self?.controls?.bringSelectedToFront(); self?.refresh() },
                UIAction(title: "Send to back", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) { [weak self] _ in self?.controls?.sendSelectedToBack(); self?.refresh() }]
            if PadActions.action(sel.action).isKey, !sel.isStick, sel.pad == nil {
                selected.append(UIMenu(title: "Combo: also hold\u{2026}", children: TouchControlSpec.comboModifiers.filter { $0 != sel.action }.map { id in
                    UIAction(title: PadActions.label(id), state: sel.with.contains(id) ? .on : .off) { [weak self] _ in self?.controls?.toggleComboModifier(id); self?.refresh() }
                }))
            }
            if !sel.isStick, sel.pad == nil, sel.action != "keyboard" {
                selected.append(UIMenu(title: "Shape", children: [(nil, "Round"), ("rounded", "Rounded square"), ("square", "Square")].map { (value, title) in
                    UIAction(title: title, state: (sel.shape ?? "") == (value ?? "") || (value == nil && sel.shape == "round") ? .on : .off) { [weak self] _ in self?.controls?.setShape(value); self?.refresh() }
                }))
                selected.append(UIMenu(title: "Colour", children: [(nil as String?, "Default"), ("red", "Red"), ("orange", "Orange"), ("yellow", "Yellow"), ("green", "Green"), ("blue", "Blue"), ("purple", "Purple"), ("white", "White")].map { (value, title) in
                    UIAction(title: title, state: (sel.colour ?? "") == (value ?? "") ? .on : .off) { [weak self] _ in self?.controls?.setColour(value); self?.refresh() }
                }))
            }
            children.append(UIMenu(title: "Selected control", options: .displayInline, children: selected))
        }
        optionsButton.menu = UIMenu(children: children)
    }

    private func refresh() {
        guard let c = controls else { return }
        rebuildOptionsMenu()
        startButton.isEnabled = c.layout?.locked != true; startButton.alpha = startButton.isEnabled ? 1 : 0.4
        undoButton.isEnabled = c.canUndo; redoButton.isEnabled = c.canRedo
        undoButton.alpha = c.canUndo ? 1 : 0.4; redoButton.alpha = c.canRedo ? 1 : 0.4
        lookButton.setTitle("Look \(c.layout?.look == true ? "on" : "off")", for: .normal)
        lookButton.backgroundColor = c.layout?.look == true ? UIColor.systemGreen.withAlphaComponent(0.8) : UIColor(white: 1, alpha: 0.16)
        let sel = selection
        if sel != nil { trayOpen = false }
        bottom.isHidden = sel == nil && !trayOpen
        addButton.setTitle(trayOpen ? "\u{2212} Tray" : "+ Add", for: .normal)
        addButton.backgroundColor = trayOpen ? UIColor.systemYellow.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.16)
        addButton.setTitleColor(trayOpen ? .black : .white, for: .normal)
        tray.isHidden = sel != nil; settings.isHidden = sel == nil
        if sel != nil { dismissHint() }
        refreshValues()
        // The panel never sits on top of the control it edits: use whichever edge the control is clear of, and only fall back to
        // "opposite half" when it is clear of neither.
        var atTop = false
        if sel != nil, let f = c.selectedFrame {
            let h = max(bottom.bounds.height, 130)
            let clearOfTop = f.minY > topBar.frame.maxY + 14 + h, clearOfBottom = f.maxY < bounds.height - safeAreaInsets.bottom - 14 - h
            atTop = clearOfTop && !clearOfBottom ? true : (clearOfBottom && !clearOfTop ? false : f.midY > bounds.midY)
        }
        if atTop != bottomAtTop.isActive {
            bottomAtBottom.isActive = !atTop; bottomAtTop.isActive = atTop
            UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
        }
    }

    private func refreshValues() {
        guard let sel = controls?.selectedSpec else { return }
        selection = sel
        let action = PadActions.action(sel.action)
        doesButton.setTitle(sel.isStick ? "Stick: \(sel.action == "stick-arrows" ? "arrows" : "W A S D") \u{25BE}" : "Does: \(PadActions.label(sel.action).prefix(16)) \u{25BE}", for: .normal)
        latchButton.isHidden = !(action.isKey || sel.pad?.isButtonLike == true)
        let latched = sel.mode == "latch"
        latchButton.setTitle(latched ? "Latch: on" : "Latch: off", for: .normal)
        latchButton.backgroundColor = latched ? .systemYellow : UIColor(white: 1, alpha: 0.16)
        latchButton.setTitleColor(latched ? .black : .white, for: .normal)
        labelButton.isHidden = sel.isRound
        if !sizeSlider.isTracking { sizeSlider.value = Float(sel.size) }
        sizeLabel.text = "\(Int(sel.size))"
        copyButton.isEnabled = (controls?.layout?.controls.count ?? 0) < TouchLayout.maxControls
    }

    private func sizeChanged(_ phase: UIGestureRecognizer.State) {
        controls?.adjustSelectedSize(Double(sizeSlider.value), phase: phase)
        sizeLabel.text = "\(Int(sizeSlider.value.rounded()))"
    }

    // MARK: Choosing

    private func chooseAction() {
        guard let sel = selection else { return }
        showPicker(sticks: sel.isRound, current: sel.action) { [weak self] id in
            self?.controls?.changeSelected { spec in
                // The face follows the action while it still shows the old action's name.
                if spec.label.isEmpty || spec.label == PadActions.shortLabel(spec.action) { spec.label = spec.isRound || id.hasPrefix("stick") || id.hasPrefix("dpad") ? "" : PadActions.shortLabel(id) }
                spec.action = id
                if ["lmb", "rmb", "mmb"].contains(id) { spec.mode = "hold" }
            }
        }
    }

    private func showPicker(sticks: Bool, current: String?, pick: @escaping (String) -> Void) {
        picker?.removeFromSuperview()
        let p = KeyPickerView(sticks: sticks, current: current) { [weak self] id in self?.picker?.removeFromSuperview(); self?.picker = nil; if let id { pick(id) } }
        p.translatesAutoresizingMaskIntoConstraints = false
        addSubview(p)
        NSLayoutConstraint.activate([p.centerXAnchor.constraint(equalTo: centerXAnchor), p.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     p.widthAnchor.constraint(equalToConstant: 540), p.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, constant: -24),
                                     p.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor, constant: -16), p.heightAnchor.constraint(equalToConstant: 330).withPriority(.defaultHigh)])
        picker = p
    }

    private func askLabel() {
        guard let current = selection else { return }
        let alert = UIAlertController(title: "Label", message: "Up to 8 characters shown on the control.", preferredStyle: .alert)
        alert.addTextField { $0.text = current.label; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let text = String((alert?.textFields?.first?.text ?? "").prefix(8))
            self?.controls?.changeSelected { $0.label = text }
        })
        Self.present(alert)
    }

    // MARK: Dragging a tile out of the tray

    fileprivate func tileTapped(_ tile: TrayTile) {
        dismissHint()
        if tile.action == "more" { showPicker(sticks: false, current: nil) { [weak self] id in self?.controls?.addControl(action: id) }; return }
        controls?.addControl(action: tile.action)
    }

    fileprivate func tileDragged(_ tile: TrayTile, _ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dismissHint()
            let side: CGFloat = tile.action.hasPrefix("stick") ? 110 : 54
            let v = UILabel(frame: CGRect(x: 0, y: 0, width: side, height: side))
            v.text = tile.action.hasPrefix("stick") ? "" : tile.face; v.textColor = .white; v.textAlignment = .center; v.font = .systemFont(ofSize: 16, weight: .bold)
            v.backgroundColor = UIColor(white: 0, alpha: 0.6); v.layer.cornerRadius = side / 2; v.layer.masksToBounds = true
            v.layer.borderWidth = 2; v.layer.borderColor = UIColor.systemYellow.cgColor
            v.center = p; v.alpha = 0.9; addSubview(v); ghost = v
            tray.isScrollEnabled = false          // the finger is carrying a tile now, not scrolling
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            ghost?.center = p
        case .ended:
            tray.isScrollEnabled = true
            ghost?.removeFromSuperview(); ghost = nil
            let overPanel = bottom.frame.contains(p) || topBar.frame.contains(p)
            if !overPanel, let c = controls { c.addControl(action: tile.action, at: convert(p, to: c)); UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        case .cancelled, .failed:
            tray.isScrollEnabled = true
            ghost?.removeFromSuperview(); ghost = nil
        default: break
        }
    }

    // MARK: Hits and presenting

    /// Only the panels take touches; everything else goes to the controls underneath (to move, resize and select them), never to the game.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    /// The topmost view controller, for the alerts the editor shows.
    static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(controller, animated: true)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint { priority = p; return self }
}

/// The dark rounded panels of the editor.
final class ControlsEditorPanel: UIVisualEffectView {
    init() {
        super.init(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        layer.cornerRadius = 16; layer.masksToBounds = true
        layer.borderWidth = 1; layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One thing in the tray: tap to add it, drag it onto the screen to place it. A mostly sideways drag scrolls the tray instead.
private final class TrayTile: UIControl, UIGestureRecognizerDelegate {
    let action: String, face: String
    private weak var editor: ControlsEditorView?

    init(action: String, face: String, editor: ControlsEditorView) {
        self.action = action; self.face = face; self.editor = editor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: action.hasPrefix("stick") ? 74 : 62).isActive = true
        heightAnchor.constraint(equalToConstant: 62).isActive = true
        backgroundColor = UIColor(white: 1, alpha: 0.14); layer.cornerRadius = 14
        let l = UILabel(); l.text = action.hasPrefix("stick") ? "\u{25CE}\n\(face)" : face
        l.numberOfLines = 0; l.textAlignment = .center; l.textColor = .white; l.font = .systemFont(ofSize: action.hasPrefix("stick") ? 12 : 15, weight: .bold)
        l.adjustsFontSizeToFitWidth = true; l.minimumScaleFactor = 0.6; l.isUserInteractionEnabled = false
        l.translatesAutoresizingMaskIntoConstraints = false; addSubview(l)
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), l.centerYAnchor.constraint(equalTo: centerYAnchor)])
        addAction(UIAction { [weak self] _ in guard let self else { return }; self.editor?.tileTapped(self) }, for: .touchUpInside)
        if action != "more" {
            // Hold a moment, then drag in any direction. A quick swipe never reaches this and scrolls the tray, so the tray is easy to scroll and the tiles easy to drag.
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
            hold.minimumPressDuration = 0.18; hold.allowableMovement = 12
            addGestureRecognizer(hold)
        }
        accessibilityLabel = "Add \(face)"; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func dragged(_ g: UILongPressGestureRecognizer) { editor?.tileDragged(self, g) }
}

/// Every key, mouse button and wheel the editor can give a control, in groups, as buttons to tap (or the two sticks).
private final class KeyPickerView: UIView {
    private let panel = ControlsEditorPanel(), scroll = UIScrollView()
    private var chips: [UIButton] = [], headers: [UILabel] = []
    private let groups: [(title: String, ids: [String])]
    private let pick: (String?) -> Void

    init(sticks: Bool, current: String?, pick: @escaping (String?) -> Void) {
        self.pick = pick
        groups = sticks ? [("Stick or D-pad", ["stick-wasd", "stick-arrows", "stick-ls", "stick-rs", "dpad-pad"])] : PadActions.groups
        super.init(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false; addSubview(panel)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let title = UILabel(); title.text = sticks ? "What the stick does" : "What it does"; title.textColor = .white; title.font = .systemFont(ofSize: 15, weight: .bold)
        let close = UIButton(type: .system); close.setTitle("Cancel", for: .normal); close.setTitleColor(.white, for: .normal); close.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        close.addAction(UIAction { [weak self] _ in self?.pick(nil) }, for: .touchUpInside)
        for v in [title, close, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; panel.contentView.addSubview(v) }
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 12),
                                     close.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -12), close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                                     scroll.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
                                     scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor)])
        for group in groups {
            let h = UILabel(); h.text = group.title.uppercased(); h.textColor = UIColor(white: 1, alpha: 0.6); h.font = .systemFont(ofSize: 11, weight: .bold)
            scroll.addSubview(h); headers.append(h)
            for id in group.ids {
                let b = UIButton(type: .system)
                b.setTitle(id == "stick-arrows" ? "Arrow keys" : (id == "stick-wasd" ? "W A S D" : (TouchPadControl.entry(id)?.control.isRound == true ? PadActions.label(id) : (id == "lookmode" ? "Look / Mouse switch" : PadActions.shortLabel(id).isEmpty ? PadActions.label(id) : PadActions.shortLabel(id)))), for: .normal)
                b.setTitleColor(id == current ? .black : .white, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                b.backgroundColor = id == current ? .systemYellow : UIColor(white: 1, alpha: 0.16); b.layer.cornerRadius = 13
                b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 11, bottom: 6, right: 11)
                b.addAction(UIAction { [weak self] _ in self?.pick(id) }, for: .touchUpInside)
                b.accessibilityLabel = PadActions.label(id)
                scroll.addSubview(b); chips.append(b)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - 28, gap: CGFloat = 8
        var y: CGFloat = 4, index = 0
        for (g, group) in groups.enumerated() {
            headers[g].frame = CGRect(x: 14, y: y, width: width, height: 16); y += 22
            var x: CGFloat = 14
            for _ in group.ids {
                let b = chips[index]; index += 1
                let size = b.sizeThatFits(CGSize(width: 200, height: 30)), w = max(size.width, 44), h: CGFloat = 30
                if x + w > 14 + width { x = 14; y += h + gap }
                b.frame = CGRect(x: x, y: y, width: w, height: h); x += w + gap
            }
            y += 30 + 14
        }
        scroll.contentSize = CGSize(width: bounds.width, height: y + 8)
    }
}
