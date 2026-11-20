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
    private let selectButton = ControlsEditorView.chip("Select")
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
    /// The single selected control (nil when none or several are selected), and everything selected.
    private var selection: TouchControlSpec?
    private var selections: [TouchControlSpec] = []

    // The panel for several selected controls: line up, space out, flip, one size, copy, delete.
    private let multi = UIStackView()
    private let countLabel = UILabel()
    private let alignButton = ControlsEditorView.chip("Align \u{25BE}"), spreadButton = ControlsEditorView.chip("Space \u{25BE}"), flipButton = ControlsEditorView.chip("Flip")
    private let multiCopyButton = ControlsEditorView.chip("Copy"), multiDeleteButton = ControlsEditorView.chip("Delete"), multiCloseButton = ControlsEditorView.chip("\u{2715}")
    private let multiSlider = UISlider(), multiSizeLabel = UILabel()

    // Nudge: arrows for placing the selection exactly, behind a button so the panel stays as it was until they are asked for.
    private var nudgeOpen = false, nudgeFine = true
    private let nudgeToggle = ControlsEditorView.chip("Nudge"), multiNudgeToggle = ControlsEditorView.chip("Nudge")
    private var nudgeRows: [UIStackView] = [], nudgeSteps: [UIButton] = []

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
        // Where the performance numbers and the people in a Discord call go while playing.
        ("overlay-perf", "Perf\nnumbers"), ("overlay-discord", "Discord\ncall"),
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
        let row = UIStackView(arrangedSubviews: [doneButton, addButton, selectButton, undoButton, redoButton, startButton, lookButton, optionsButton])
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
        hint.text = "  Tap + Add, then tap a tile or hold it and drag it in \u{00B7} drag to move \u{00B7} drag the corner dot or pinch to resize \u{00B7} drag across empty space to select several \u{00B7} tap a control to change it  "
        addSubview(hint)
        NSLayoutConstraint.activate([topBar.centerXAnchor.constraint(equalTo: centerXAnchor), topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
                                     topBar.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
                                     topBar.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
                                     hint.centerXAnchor.constraint(equalTo: centerXAnchor), hint.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
                                     hint.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
                                     hint.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12)])
        startButton.showsMenuAsPrimaryAction = true
        optionsButton.showsMenuAsPrimaryAction = true
        // Every layout Porthole ships (ShippedLayouts.all), then an empty screen.
        let shipped = ShippedLayouts.all.map { l in UIAction(title: "\(l.title) layout") { [weak self] _ in self?.controls?.replaceLayout(l.layout) } }
        startButton.menu = UIMenu(title: "Replace every control with\u{2026} (Undo brings them back)", children: shipped + [
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
        let second = UIStackView(arrangedSubviews: [latchButton, Self.caption("Size"), sizeSlider, sizeLabel, nudgeToggle])
        second.axis = .horizontal; second.spacing = 8; second.alignment = .center
        settings.axis = .vertical; settings.spacing = 10; settings.addArrangedSubview(first); settings.addArrangedSubview(second); settings.addArrangedSubview(makeNudgeRow())
        multiDeleteButton.setTitleColor(.systemRed, for: .normal)
        countLabel.textColor = .white; countLabel.font = .systemFont(ofSize: 14, weight: .bold)
        multiSlider.minimumValue = Float(TouchLayout.sizeRange.lowerBound); multiSlider.maximumValue = Float(TouchLayout.sizeRange.upperBound)
        multiSlider.minimumTrackTintColor = .systemYellow; multiSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        multiSizeLabel.textColor = .white; multiSizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium); multiSizeLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let multiFirst = UIStackView(arrangedSubviews: [countLabel, alignButton, spreadButton, flipButton, UIView(), multiCopyButton, multiDeleteButton, multiCloseButton])
        multiFirst.axis = .horizontal; multiFirst.spacing = 8; multiFirst.alignment = .center
        let multiSecond = UIStackView(arrangedSubviews: [Self.caption("Size of all"), multiSlider, multiSizeLabel, multiNudgeToggle])
        multiSecond.axis = .horizontal; multiSecond.spacing = 8; multiSecond.alignment = .center
        multi.axis = .vertical; multi.spacing = 10; multi.addArrangedSubview(multiFirst); multi.addArrangedSubview(multiSecond); multi.addArrangedSubview(makeNudgeRow())
        // The size numbers can be tapped to type an exact size.
        for label in [sizeLabel, multiSizeLabel] { label.isUserInteractionEnabled = true; label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(askSize))) }
        for v in [tray, settings, multi] { v.translatesAutoresizingMaskIntoConstraints = false; bottom.contentView.addSubview(v) }
        NSLayoutConstraint.activate([tray.leadingAnchor.constraint(equalTo: bottom.contentView.leadingAnchor), tray.trailingAnchor.constraint(equalTo: bottom.contentView.trailingAnchor),
                                     tray.topAnchor.constraint(equalTo: bottom.contentView.topAnchor), tray.bottomAnchor.constraint(equalTo: bottom.contentView.bottomAnchor), tray.heightAnchor.constraint(equalToConstant: 86),
                                     settings.leadingAnchor.constraint(equalTo: bottom.contentView.leadingAnchor, constant: 12), settings.trailingAnchor.constraint(equalTo: bottom.contentView.trailingAnchor, constant: -12),
                                     settings.topAnchor.constraint(equalTo: bottom.contentView.topAnchor, constant: 10), settings.bottomAnchor.constraint(equalTo: bottom.contentView.bottomAnchor, constant: -10),
                                     multi.leadingAnchor.constraint(equalTo: bottom.contentView.leadingAnchor, constant: 12), multi.trailingAnchor.constraint(equalTo: bottom.contentView.trailingAnchor, constant: -12),
                                     multi.topAnchor.constraint(equalTo: bottom.contentView.topAnchor, constant: 10), multi.bottomAnchor.constraint(equalTo: bottom.contentView.bottomAnchor, constant: -10)])
        settings.isHidden = true; multi.isHidden = true
        alignButton.showsMenuAsPrimaryAction = true; spreadButton.showsMenuAsPrimaryAction = true
        alignButton.menu = UIMenu(title: "Line up the selected controls", children: [
            UIAction(title: "Left edges", image: UIImage(systemName: "align.horizontal.left")) { [weak self] _ in self?.controls?.align(.left) },
            UIAction(title: "Centres", image: UIImage(systemName: "align.horizontal.center")) { [weak self] _ in self?.controls?.align(.centreX) },
            UIAction(title: "Right edges", image: UIImage(systemName: "align.horizontal.right")) { [weak self] _ in self?.controls?.align(.right) },
            UIAction(title: "Top edges", image: UIImage(systemName: "align.vertical.top")) { [weak self] _ in self?.controls?.align(.top) },
            UIAction(title: "Middles", image: UIImage(systemName: "align.vertical.center")) { [weak self] _ in self?.controls?.align(.centreY) },
            UIAction(title: "Bottom edges", image: UIImage(systemName: "align.vertical.bottom")) { [weak self] _ in self?.controls?.align(.bottom) }])
    }

    /// One row of Nudge arrows (the panel of one control and the panel of several each have one): a press moves the selection a step, holding repeats it, and the step is 1 point or 6.
    private func makeNudgeRow() -> UIStackView {
        let step = ControlsEditorView.chip("1 pt")
        step.addAction(UIAction { [weak self] _ in self?.nudgeFine.toggle(); self?.refresh() }, for: .touchUpInside)
        nudgeSteps.append(step)
        let row = UIStackView(arrangedSubviews: [Self.caption("Nudge"), nudgeButton("arrow.left", dx: -1, dy: 0), nudgeButton("arrow.up", dx: 0, dy: -1), nudgeButton("arrow.down", dx: 0, dy: 1),
                                                 nudgeButton("arrow.right", dx: 1, dy: 0), step, UIView()])
        row.axis = .horizontal; row.spacing = 8; row.alignment = .center; row.isHidden = true
        nudgeRows.append(row)
        return row
    }

    private func nudgeButton(_ symbol: String, dx: CGFloat, dy: CGFloat) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
        b.tintColor = .white; b.backgroundColor = UIColor(white: 1, alpha: 0.16); b.layer.cornerRadius = 10
        b.widthAnchor.constraint(equalToConstant: 46).isActive = true; b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        var timer: Timer?
        let stepOnce = { [weak self] in
            guard let self else { return }
            let k: CGFloat = self.nudgeFine ? 1 : 6
            self.controls?.nudge(dx: dx * k, dy: dy * k)
        }
        b.addAction(UIAction { [weak self] _ in
            self?.controls?.nudgeBegan(); stepOnce()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in stepOnce() } }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in timer?.invalidate(); timer = nil; self?.controls?.nudgeEnded() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    /// The number beside the size slider was tapped: ask for an exact size.
    @objc private func askSize() {
        guard let first = controls?.selectedSpec ?? controls?.selectedSpecs.first else { return }
        let alert = UIAlertController(title: "Size", message: "A width in points, from \(Int(TouchLayout.sizeRange.lowerBound)) to \(Int(TouchLayout.sizeRange.upperBound)). \(selections.count > 1 ? "Every selected control gets it." : "")", preferredStyle: .alert)
        alert.addTextField { $0.text = "\(Int(first.size))"; $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            if let text = alert?.textFields?.first?.text, let v = Double(text) { self?.controls?.setSelectedSize(v) }
        })
        Self.present(alert)
    }

    private static func caption(_ text: String) -> UILabel {
        let l = UILabel(); l.text = text; l.textColor = UIColor(white: 1, alpha: 0.75); l.font = .systemFont(ofSize: 13, weight: .medium); return l
    }

    private func wire() {
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        addButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.trayOpen = !(self.trayOpen && self.selections.isEmpty)
            if !self.selections.isEmpty { self.trayOpen = true; self.controls?.select(nil) }      // from a control's settings: let go of it and show the tray
            self.dismissHint(); self.refresh()
        }, for: .touchUpInside)
        undoButton.addAction(UIAction { [weak self] _ in self?.controls?.undo(); self?.refresh() }, for: .touchUpInside)
        redoButton.addAction(UIAction { [weak self] _ in self?.controls?.redo(); self?.refresh() }, for: .touchUpInside)
        lookButton.addAction(UIAction { [weak self] _ in guard let c = self?.controls else { return }; c.setLook(!(c.layout?.look ?? false)); self?.refresh() }, for: .touchUpInside)
        selectButton.addAction(UIAction { [weak self] _ in guard let c = self?.controls else { return }; c.multiSelect = !c.multiSelect; self?.dismissHint() }, for: .touchUpInside)
        multiCopyButton.addAction(UIAction { [weak self] _ in self?.controls?.duplicateSelected() }, for: .touchUpInside)
        multiDeleteButton.addAction(UIAction { [weak self] _ in self?.controls?.removeSelected() }, for: .touchUpInside)
        multiCloseButton.addAction(UIAction { [weak self] _ in self?.controls?.select(nil) }, for: .touchUpInside)
        flipButton.addAction(UIAction { [weak self] _ in self?.controls?.mirror(wholeLayout: false) }, for: .touchUpInside)
        multiSlider.addAction(UIAction { [weak self] _ in self?.multiSizeChanged(.changed) }, for: .valueChanged)
        multiSlider.addAction(UIAction { [weak self] _ in self?.multiSizeChanged(.began) }, for: .touchDown)
        multiSlider.addAction(UIAction { [weak self] _ in self?.multiSizeChanged(.ended) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        for toggle in [nudgeToggle, multiNudgeToggle] { toggle.addAction(UIAction { [weak self] _ in self?.nudgeOpen.toggle(); self?.refresh() }, for: .touchUpInside) }
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
        c.onSelection = { [weak self] specs in self?.selections = specs; self?.selection = specs.count == 1 ? specs[0] : nil; self?.refresh() }
        c.onSelectMode = { [weak self] in self?.refresh() }
        c.onHistory = { [weak self] in self?.refresh() }
        c.onEdited = { [weak self] in self?.refreshValues() }
        selection = nil; selections = []; trayOpen = false
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
        let picture = Self.pictureMenu(layout.picture) { [weak self] placement in self?.controls?.setPicture(placement); self?.refresh() }
        // Button size is one setting for the device (Settings > Controls > Touch screen has the same choice): drawn again at once so it can be judged against the layout.
        let sizeSetting = UserDefaults.standard.string(forKey: TouchButtonSize.key) ?? ""
        let buttonSize = UIMenu(title: "Button size (every layout on this device)", children: TouchButtonSize.choices.map { choice in
            UIAction(title: choice.title, state: choice.value == sizeSetting ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(choice.value, forKey: TouchButtonSize.key); self?.controls?.buttonSizeChanged(); self?.refresh()
            }
        })
        var children: [UIMenuElement] = [picture, opacity, buttonSize,
            UIAction(title: "Tap feedback (haptics)", state: layout.haptics ? .on : .off) { [weak self] _ in self?.controls?.setHaptics(!layout.haptics); self?.refresh() },
            UIAction(title: "Lock positions and sizes", image: UIImage(systemName: layout.locked ? "lock.fill" : "lock.open"), state: layout.locked ? .on : .off) { [weak self] _ in self?.controls?.setLocked(!layout.locked); self?.refresh() }]
        let locked = layout.locked
        let group = UIMenu(title: "Several controls", options: .displayInline, children: [
            UIAction(title: "Select all", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.controls?.selectAll() },
            UIAction(title: "Mirror the whole layout (left-handed)", image: UIImage(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right"), attributes: locked ? .disabled : []) { [weak self] _ in self?.controls?.mirror(wholeLayout: true) },
            UIAction(title: "Copy selection to another layout", image: UIImage(systemName: "doc.on.doc"), attributes: selections.isEmpty ? .disabled : []) { [weak self] _ in self?.controls?.copySelectionToClipboard(); self?.refresh() },
            UIAction(title: ControlClipboard.count > 0 ? "Paste \(ControlClipboard.count) copied control\(ControlClipboard.count == 1 ? "" : "s") here" : "Paste copied controls here", image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: locked || ControlClipboard.count == 0 ? .disabled : []) { [weak self] _ in self?.controls?.pasteClipboard() }])
        children.append(group)
        if !selections.isEmpty {
            var selected: [UIMenuElement] = [
                UIAction(title: "Bring to front", image: UIImage(systemName: "square.2.layers.3d.top.filled")) { [weak self] _ in self?.controls?.bringSelectedToFront(); self?.refresh() },
                UIAction(title: "Send to back", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) { [weak self] _ in self?.controls?.sendSelectedToBack(); self?.refresh() }]
            let sel = selections.first!, one = selections.count == 1
            if one, PadActions.action(sel.action).isKey, !sel.isStick, sel.pad == nil {
                selected.append(UIMenu(title: "Combo: also hold\u{2026}", children: TouchControlSpec.comboModifiers.filter { $0 != sel.action }.map { id in
                    UIAction(title: PadActions.label(id), state: sel.with.contains(id) ? .on : .off) { [weak self] _ in self?.controls?.toggleComboModifier(id); self?.refresh() }
                }))
            }
            // Shape and colour are for keys and mouse buttons: with several selected they go to every one that has them.
            if selections.contains(where: \.canTakeShape) {
                selected.append(UIMenu(title: "Shape", children: [(nil, "Round"), ("rounded", "Rounded square"), ("square", "Square")].map { (value, title) in
                    UIAction(title: title, state: (sel.shape ?? "") == (value ?? "") || (value == nil && sel.shape == "round") ? .on : .off) { [weak self] _ in self?.controls?.setShape(value); self?.refresh() }
                }))
                selected.append(UIMenu(title: "Colour", children: [(nil as String?, "Default"), ("red", "Red"), ("orange", "Orange"), ("yellow", "Yellow"), ("green", "Green"), ("blue", "Blue"), ("purple", "Purple"), ("white", "White")].map { (value, title) in
                    UIAction(title: title, state: (sel.colour ?? "") == (value ?? "") ? .on : .off) { [weak self] _ in self?.controls?.setColour(value); self?.refresh() }
                }))
            }
            children.append(UIMenu(title: one ? "Selected control" : "Selected controls", options: .displayInline, children: selected))
        }
        optionsButton.menu = UIMenu(children: children)
    }

    /// "Game picture": where the picture goes while this layout is on screen (so the controls can be planned around it), and how big. Automatic leaves it to Porthole.
    private static func pictureMenu(_ current: PicturePlacement?, set: @escaping (PicturePlacement?) -> Void) -> UIMenu {
        let names: [[(String, Double, Double)]] = [[("Top left", 0, 0), ("Top", 0.5, 0), ("Top right", 1, 0)],
                                                  [("Left", 0, 0.5), ("Middle", 0.5, 0.5), ("Right", 1, 0.5)],
                                                  [("Bottom left", 0, 1), ("Bottom", 0.5, 1), ("Bottom right", 1, 1)]]
        let automatic = UIAction(title: "Automatic", subtitle: "Porthole decides", state: current == nil ? .on : .off) { _ in set(nil) }
        let positions = UIMenu(title: "Position", image: UIImage(systemName: "rectangle.center.inset.filled"), children: names.flatMap { $0 }.map { name, across, down in
            UIAction(title: name, state: current.map { $0.across == across && $0.down == down } == true ? .on : .off) { _ in
                set(PicturePlacement(across: across, down: down, scale: current?.scale ?? 1))
            }
        })
        let sizes = UIMenu(title: "Size", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), children: PicturePlacement.scales.map { scale in
            UIAction(title: scale == 1 ? "As big as it fits" : "\(Int(scale * 100))%", state: current.map { abs($0.scale - scale) < 0.02 } == true ? .on : .off) { _ in
                set(PicturePlacement(across: current?.across ?? 0.5, down: current?.down ?? 0.5, scale: scale))
            }
        })
        return UIMenu(title: "Game picture", image: UIImage(systemName: "rectangle.inset.filled"), children: [automatic, positions, sizes])
    }

    private func refresh() {
        guard let c = controls else { return }
        rebuildOptionsMenu()
        startButton.isEnabled = c.layout?.locked != true; startButton.alpha = startButton.isEnabled ? 1 : 0.4
        undoButton.isEnabled = c.canUndo; redoButton.isEnabled = c.canRedo
        undoButton.alpha = c.canUndo ? 1 : 0.4; redoButton.alpha = c.canRedo ? 1 : 0.4
        lookButton.setTitle("Look \(c.layout?.look == true ? "on" : "off")", for: .normal)
        lookButton.backgroundColor = c.layout?.look == true ? UIColor.systemGreen.withAlphaComponent(0.8) : UIColor(white: 1, alpha: 0.16)
        let sel = selection, any = !selections.isEmpty
        if any { trayOpen = false }
        bottom.isHidden = !any && !trayOpen
        addButton.setTitle(trayOpen ? "\u{2212} Tray" : "+ Add", for: .normal)
        addButton.backgroundColor = trayOpen ? UIColor.systemYellow.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.16)
        addButton.setTitleColor(trayOpen ? .black : .white, for: .normal)
        let on = c.multiSelect
        selectButton.setTitle(on ? "Select: on" : "Select", for: .normal)
        selectButton.backgroundColor = on ? UIColor.systemYellow.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.16)
        selectButton.setTitleColor(on ? .black : .white, for: .normal)
        tray.isHidden = any; settings.isHidden = sel == nil; multi.isHidden = selections.count < 2
        for toggle in [nudgeToggle, multiNudgeToggle] {
            toggle.backgroundColor = nudgeOpen ? UIColor.systemYellow.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.16)
            toggle.setTitleColor(nudgeOpen ? .black : .white, for: .normal)
        }
        nudgeRows.forEach { $0.isHidden = !nudgeOpen }
        nudgeSteps.forEach { $0.setTitle(nudgeFine ? "1 pt" : "6 pt", for: .normal) }
        if any { dismissHint() }
        refreshValues()
        // The panel never sits on top of the control it edits: use whichever edge the control is clear of, and only fall back to
        // "opposite half" when it is clear of neither.
        var atTop = false
        if any, let f = c.selectedFrame {
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
        if selections.count > 1, let c = controls {
            countLabel.text = "\(selections.count) selected"
            let locked = c.layout?.locked == true
            let specs = c.selectedSpecs, common = ControlArrange.commonSize(specs)
            if !multiSlider.isTracking { multiSlider.value = Float(common ?? specs.map(\.size).reduce(0, +) / Double(max(specs.count, 1))) }
            multiSizeLabel.text = common.map { "\(Int($0))" } ?? "\u{2013}"
            [alignButton, flipButton, multiCopyButton, multiDeleteButton, multiSlider].forEach { ($0 as UIControl).isEnabled = !locked || $0 === multiCopyButton }
            spreadButton.isEnabled = !locked
            multiCopyButton.isEnabled = TouchLayout.maxControls - (c.layout?.controls.count ?? 0) > 0
            spreadButton.menu = UIMenu(title: "Space the selected controls evenly", children: [
                UIAction(title: "Across", image: UIImage(systemName: "distribute.horizontal.center"), attributes: selections.count < 3 ? .disabled : []) { [weak self] _ in self?.controls?.distribute(.across) },
                UIAction(title: "Down", image: UIImage(systemName: "distribute.vertical.center"), attributes: selections.count < 3 ? .disabled : []) { [weak self] _ in self?.controls?.distribute(.down) }])
            return
        }
        guard let sel = controls?.selectedSpec else { return }
        selection = sel
        let action = PadActions.action(sel.action)
        doesButton.setTitle(sel.isOverlay ? "\(sel.overlayName) overlay goes here" : (sel.isStick ? "Stick: \(sel.action == "stick-arrows" ? "arrows" : "W A S D") \u{25BE}" : "Does: \(PadActions.label(sel.action).prefix(16)) \u{25BE}"), for: .normal)
        doesButton.isEnabled = !sel.isOverlay
        latchButton.isHidden = sel.isOverlay || !(action.isKey || sel.pad?.isButtonLike == true)
        let latched = sel.mode == "latch"
        latchButton.setTitle(latched ? "Latch: on" : "Latch: off", for: .normal)
        latchButton.backgroundColor = latched ? .systemYellow : UIColor(white: 1, alpha: 0.16)
        latchButton.setTitleColor(latched ? .black : .white, for: .normal)
        labelButton.isHidden = sel.isRound || sel.isOverlay
        if !sizeSlider.isTracking { sizeSlider.value = Float(sel.size) }
        sizeLabel.text = "\(Int(sel.size))"
        copyButton.isEnabled = (controls?.layout?.controls.count ?? 0) < TouchLayout.maxControls
    }

    private func multiSizeChanged(_ phase: UIGestureRecognizer.State) {
        controls?.adjustSelectedSize(Double(multiSlider.value), phase: phase)
        multiSizeLabel.text = "\(Int(multiSlider.value.rounded()))"
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
