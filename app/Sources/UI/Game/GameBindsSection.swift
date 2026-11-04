// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A game's page, "Binds" section: several named sets of controls (controller binds and/or a touch layout), one in use at a time. With none in use the game keeps
/// its own Controls and Engine settings, untouched; a set is only a layer on top, and never writes those settings.
struct GameBindsSection: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @State private var editing: UUID?
    @State private var importing = false
    @State private var browsing = false
    @State private var message: String?

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        if let g = game {
            let sets = g.bindSets ?? []
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(title: "In use") {
                    ChoiceRow(id: "bs-active", symbol: "checkmark.circle.fill", title: "Bind set in use",
                              info: "Only one set is used at a time. Standard leaves this game's own Controls and Engine settings exactly as they are. A set with controller binds switches the controller to keyboard and mouse for this game; a set with a touch layout replaces the on-screen controls. Applies the next time the game starts.",
                              options: [(UUID?.none, "Standard")] + sets.map { (Optional($0.id), $0.name) },
                              selection: Binding(get: { g.activeBindSetID.flatMap { id in sets.contains { $0.id == id } ? id : nil } }, set: { v in model.update(g) { $0.activeBindSetID = v } }))
                    if let active = g.activeBindSet {
                        Text("\(active.name): \(active.summary.lowercased()).").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                    }
                }
                SettingsGroup(title: "Your sets") {
                    ForEach(sets) { set in
                        ActionRow(id: "bs-\(set.id)", symbol: set.id == g.activeBindSetID ? "checkmark.circle.fill" : "keyboard", title: set.name, subtitle: set.summary,
                                  detail: set.id == g.activeBindSetID ? "In use" : nil) { editing = set.id }
                    }
                    if sets.isEmpty {
                        Text("No sets yet. Make one from this game's current controls, or import one from a file.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                    }
                    ActionRow(id: "bs-new", symbol: "plus.circle.fill", title: "New bind set", subtitle: "Starts from this game's current controller settings", chevron: false) { create(g) }
                    ActionRow(id: "bs-import", symbol: "square.and.arrow.down", title: "Import from a file\u{2026}", subtitle: ".portholebinds", chevron: false) { importing = true }
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                }
                SettingsGroup(title: "Community") {
                    ActionRow(id: "bs-browse", symbol: "person.2.fill", title: "Shared binds for this game", subtitle: "Binds and touch layouts other people shared; rate them and add the ones you like", chevron: true) { browsing = true }
                }
            }
            .sheet(isPresented: $browsing) { SharedBindsBrowser(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
            .sheet(item: Binding(get: { editing.map { EditTarget(id: $0) } }, set: { editing = $0?.id })) { target in
                BindSetEditor(gameID: gameID, setID: target.id).environmentObject(model).preferredColorScheme(Theme.scheme)
            }
            .sheet(isPresented: $importing) {
                FilePickerSheet(onPick: { urls in importing = false; if let url = urls.first { importFile(url, into: g) } }, onCancel: { importing = false })
            }
        }
    }

    private struct EditTarget: Identifiable { let id: UUID }

    /// A new set holds the game's current controller binds (when it uses keyboard and mouse), so it starts from what already works.
    private func create(_ g: Game) {
        var set = BindSet(name: uniqueName("My binds", in: g.bindSets ?? []))
        if let e = g.engine, e.controllerMode == "keys" { set.pad = PadPart(binds: e.binds ?? [:], mouseVertical: e.padMouseVertical).sanitized() }
        else { set.pad = PadPart() }
        model.update(g) { $0.bindSets = ($0.bindSets ?? []) + [set] }
        editing = set.id
    }

    private func importFile(_ url: URL, into g: Game) {
        do {
            var set = try BindSetFile.decode(try Data(contentsOf: url)).set
            set.name = uniqueName(set.name, in: g.bindSets ?? [])
            model.update(g) { $0.bindSets = ($0.bindSets ?? []) + [set] }
            message = "Imported \(set.name)."
            editing = set.id
        } catch {
            message = error.localizedDescription
        }
    }

    private func uniqueName(_ base: String, in sets: [BindSet]) -> String {
        guard sets.contains(where: { $0.name == base }) else { return base }
        var n = 2
        while sets.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - One set

struct BindSetEditor: View {
    let gameID: UUID
    let setID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var editingTouch = false
    @State private var confirmDelete = false
    @State private var confirmReplace: TouchLayout?
    @State private var share: URL?

    private var game: Game? { model.games.first { $0.id == gameID } }
    private var set: BindSet? { game?.bindSets?.first { $0.id == setID } }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Bind set").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "be-close", title: "Done", symbol: "checkmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    if let g = game, let s = set { content(g, s).frame(maxWidth: 680).frame(maxWidth: .infinity) }
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "be-close"; scope.focused = "be-close" }
        .presentationBackground(Theme.background)
        .fullScreenCover(isPresented: $editingTouch) { TouchLayoutEditor(gameID: gameID, setID: setID).environmentObject(model).preferredColorScheme(Theme.scheme) }
        .sheet(item: Binding(get: { share.map { SharedFile(url: $0) } }, set: { if $0 == nil { if let u = share { try? FileManager.default.removeItem(at: u) }; share = nil } })) { ActivityView(items: [$0.url]) }
    }

    private struct SharedFile: Identifiable { let url: URL; var id: String { url.path } }

    private func content(_ g: Game, _ s: BindSet) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "About this set") {
                TextFieldRow(id: "be-name", symbol: "textformat", title: "Name", placeholder: "Name", text: Binding(get: { s.name }, set: { v in change { $0.name = BindSetFile.clean(v, 40) } }))
                TextFieldRow(id: "be-notes", symbol: "text.alignleft", title: "Notes", placeholder: "What it is for", text: Binding(get: { s.notes }, set: { v in change { $0.notes = BindSetFile.clean(v, 300) } }))
                ToggleRow(id: "be-use", symbol: "checkmark.circle.fill", title: "Use this set", info: "Only one set is used at a time. Applies the next time the game starts.",
                          isOn: Binding(get: { g.activeBindSetID == s.id }, set: { on in model.update(g) { $0.activeBindSetID = on ? s.id : ($0.activeBindSetID == s.id ? nil : $0.activeBindSetID) } }))
            }
            padGroup(s)
            touchGroup(s)
            BindSetSharingGroup(gameID: gameID, setID: s.id)
            SettingsGroup(title: "This set") {
                ActionRow(id: "be-export", symbol: "square.and.arrow.up", title: "Export to a file", subtitle: ".portholebinds, to keep or send", chevron: false) { export(g, s) }
                ActionRow(id: "be-dup", symbol: "plus.square.on.square", title: "Duplicate", chevron: false) { duplicate(g, s) }
                ActionRow(id: "be-del", symbol: "trash", title: "Delete this set", destructive: true, chevron: false) { confirmDelete = true }
            }
        }
        .confirm("Delete \(s.name)?", message: "The set is removed from this game. Other games are not affected.", confirmTitle: "Delete", destructive: true, isPresented: $confirmDelete) {
            model.update(g) { $0.bindSets = $0.bindSets?.filter { $0.id != s.id }; if $0.activeBindSetID == s.id { $0.activeBindSetID = nil }; if $0.bindSets?.isEmpty == true { $0.bindSets = nil } }
            dismiss()
        }
        .confirm("Replace the touch layout?", message: "This set's layout is replaced by the starting point you chose.", confirmTitle: "Replace", destructive: true,
                 isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } })) {
            if let l = confirmReplace { change { $0.touch = l } }
            confirmReplace = nil
        }
    }

    // MARK: Controller part

    @ViewBuilder private func padGroup(_ s: BindSet) -> some View {
        SettingsGroup(title: "Controller") {
            ToggleRow(id: "be-pad", symbol: "gamecontroller.fill", title: "Include controller binds",
                      info: "With this on, using the set turns the controller into a keyboard and mouse for this game, with the buttons below. Off leaves the controller as it is.",
                      isOn: Binding(get: { s.pad != nil }, set: { on in change { $0.pad = on ? (PadPart()) : nil } }))
            if let pad = s.pad {
                stickRow("LS", "Left stick", "l.joystick.fill", pad, standard: "wasd")
                stickRow("RS", "Right stick", "r.joystick.fill", pad, standard: "mouse")
                ForEach(PadActions.buttons, id: \.self) { name in
                    let standard = PadActions.template[name] ?? "none"
                    ChoiceRow(id: "be-\(name)", symbol: "circle.circle", title: name, options: PadActions.list.map { ($0.id, $0.label + ($0.id == standard ? " (standard)" : "")) },
                              selection: Binding(get: { pad.binds[name] ?? standard }, set: { v in setBind(name, v == standard ? nil : v) }))
                }
                SliderRow(id: "be-vert", symbol: "arrow.up.and.down", title: "Right stick up and down speed",
                          value: Binding(get: { pad.mouseVertical ?? 1 }, set: { v in change { $0.pad?.mouseVertical = abs(v - 1) < 0.05 ? nil : v } }), range: 0.25...2.0, step: 0.05, format: { String(format: "%.2f\u{00D7}", $0) })
            }
        }
    }

    private func stickRow(_ name: String, _ title: String, _ symbol: String, _ pad: PadPart, standard: String) -> some View {
        ChoiceRow(id: "be-\(name)", symbol: symbol, title: title, options: PadActions.stickModes.map { ($0.id, $0.label + ($0.id == standard ? " (standard)" : "")) },
                  selection: Binding(get: { pad.binds[name] ?? standard }, set: { v in setBind(name, v == standard ? nil : v) }))
    }

    private func setBind(_ name: String, _ id: String?) {
        change { var p = $0.pad ?? PadPart(); if let id { p.binds[name] = id } else { p.binds.removeValue(forKey: name) }; $0.pad = p }
    }

    // MARK: Touch part

    @ViewBuilder private func touchGroup(_ s: BindSet) -> some View {
        SettingsGroup(title: "Touch controls") {
            ToggleRow(id: "be-touch", symbol: "hand.tap.fill", title: "Include a touch layout",
                      info: "With this on, using the set replaces the on-screen controls with this layout. Off keeps the game's normal Controls choice.",
                      isOn: Binding(get: { s.touch != nil }, set: { on in change { $0.touch = on ? ($0.touch ?? TouchLayout.mouseAndKeys) : nil } }))
            if let t = s.touch {
                ActionRow(id: "be-edit", symbol: "square.and.pencil", title: "Edit the layout", subtitle: "\(t.controls.count) control\(t.controls.count == 1 ? "" : "s")" + (t.look ? ", drag to look" : ""), chevron: true) { editingTouch = true }
                ActionRow(id: "be-from1", symbol: "rectangle.on.rectangle", title: "Start over from: mouse and keys", chevron: false) { replace(with: .mouseAndKeys, current: t) }
                ActionRow(id: "be-from2", symbol: "scope", title: "Start over from: first person", chevron: false) { replace(with: .firstPerson, current: t) }
                ActionRow(id: "be-from3", symbol: "rectangle.dashed", title: "Start over from: empty", chevron: false) { replace(with: TouchLayout(), current: t) }
            }
        }
    }

    private func replace(with layout: TouchLayout, current: TouchLayout) {
        if current.controls.isEmpty { change { $0.touch = layout } } else { confirmReplace = layout }
    }

    // MARK: Changes

    private func change(_ edit: (inout BindSet) -> Void) {
        guard let g = game else { return }
        model.update(g) {
            guard var sets = $0.bindSets, let i = sets.firstIndex(where: { $0.id == setID }) else { return }
            edit(&sets[i]); sets[i].updated = Date(); $0.bindSets = sets
        }
    }

    private func duplicate(_ g: Game, _ s: BindSet) {
        var copy = s; copy.id = UUID(); copy.created = Date(); copy.updated = Date()
        var n = 2; while (g.bindSets ?? []).contains(where: { $0.name == "\(s.name) \(n)" }) { n += 1 }
        copy.name = "\(s.name) \(n)"
        if var t = copy.touch { t.controls = t.controls.map { var c = $0; c.id = UUID(); return c }; copy.touch = t }
        model.update(g) { $0.bindSets = ($0.bindSets ?? []) + [copy] }
        dismiss()
    }

    private func export(_ g: Game, _ s: BindSet) {
        guard let data = try? BindSetFile.encode(s, gameName: g.name) else { return }
        let safe = String(s.name.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" }).replacingOccurrences(of: " ", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "binds" : safe).\(BindSetFile.fileExtension)")
        try? data.write(to: url, options: .atomic)
        share = url
    }
}

// MARK: - The touch layout editor

/// A full-screen sketch of the game's screen: drag a control to move it, tap it to change what it does, add more from the menu.
struct TouchLayoutEditor: View {
    let gameID: UUID
    let setID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var dragStart: [UUID: CGPoint] = [:]
    @State private var undoStack: [TouchLayout] = []
    @State private var redoStack: [TouchLayout] = []

    private var layout: TouchLayout { model.games.first { $0.id == gameID }?.bindSets?.first { $0.id == setID }?.touch ?? TouchLayout() }

    /// Applies a change; `record` is false while a drag is in progress, so one drag is one undo step.
    private func edit(record: Bool = true, _ change: (inout TouchLayout) -> Void) {
        guard let g = model.games.first(where: { $0.id == gameID }) else { return }
        if record { if undoStack.last != layout { undoStack.append(layout); if undoStack.count > 60 { undoStack.removeFirst() } }; redoStack.removeAll() }
        model.update(g) {
            guard var sets = $0.bindSets, let i = sets.firstIndex(where: { $0.id == setID }) else { return }
            var t = sets[i].touch ?? TouchLayout(); change(&t); sets[i].touch = t.sanitized(); sets[i].updated = Date(); $0.bindSets = sets
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                GeometryReader { geo in canvas(in: fit(geo.size)) }
                    .padding(.horizontal, 12)
                inspector
            }
            .padding(.vertical, 8)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Done") { dismiss() }.font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
            Button { step(undo: true) } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoStack.isEmpty).accessibilityLabel("Undo")
            Button { step(undo: false) } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redoStack.isEmpty).accessibilityLabel("Redo")
            Spacer()
            Toggle("Drag to look", isOn: Binding(get: { layout.look }, set: { v in edit { $0.look = v } })).toggleStyle(.switch).fixedSize().font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
            Menu {
                Section("Buttons") {
                    Button("Key") { add(label: "E", action: "key-E") }
                    Button("Left mouse button") { add(label: "LMB", action: "lmb", mode: "hold") }
                    Button("Right mouse button") { add(label: "RMB", action: "rmb", mode: "hold") }
                    Button("Middle mouse button") { add(label: "MMB", action: "mmb", mode: "hold") }
                    Button("Mouse wheel up") { add(label: "Wh\u{2191}", action: "wheelup") }
                    Button("Mouse wheel down") { add(label: "Wh\u{2193}", action: "wheeldown") }
                }
                Section("Sticks") {
                    Button("Stick: W A S D") { add(label: "", action: "stick-wasd", size: 110) }
                    Button("Stick: arrow keys") { add(label: "", action: "stick-arrows", size: 110) }
                }
            } label: { Label("Add", systemImage: "plus.circle.fill").font(.system(size: 16, weight: .bold, design: .rounded)) }
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
    }

    private func step(undo: Bool) {
        guard let g = model.games.first(where: { $0.id == gameID }) else { return }
        let target = undo ? undoStack.popLast() : redoStack.popLast()
        guard let target else { return }
        if undo { redoStack.append(layout) } else { undoStack.append(layout) }
        model.update(g) {
            guard var sets = $0.bindSets, let i = sets.firstIndex(where: { $0.id == setID }) else { return }
            sets[i].touch = target; sets[i].updated = Date(); $0.bindSets = sets
        }
        if let id = selected, !target.controls.contains(where: { $0.id == id }) { selected = nil }
    }

    private func add(label: String, action: String, mode: String = "tap", size: Double = 54) {
        guard layout.controls.count < TouchLayout.maxControls else { return }
        let spec = TouchControlSpec(label: label, action: action, mode: mode, x: 0.5, y: 0.5, size: size)
        edit { $0.controls.append(spec) }
        selected = spec.id
    }

    /// The largest rectangle with the screen's shape that fits.
    private func fit(_ size: CGSize) -> CGRect {
        let aspect = CGFloat(max(LaunchSettings.screenAspect, 1.2))
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func canvas(in rect: CGRect) -> some View {
        // The sketch is drawn at the size of the screen's points so a control's size looks the same as in the game.
        let scale = rect.width / max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.85)).frame(width: rect.width, height: rect.height)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .overlay(Text(layout.look ? "Drag anywhere that is not a control to look around" : "The game's screen").font(.footnote).foregroundStyle(.white.opacity(0.35)))
                .onTapGesture { selected = nil }
            ForEach(layout.controls) { c in
                interactiveMarker(c, rect: rect, scale: scale)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func accessibleName(_ c: TouchControlSpec) -> String {
        if c.isStick { return c.action == "stick-arrows" ? "Stick, arrow keys" : "Stick, W A S D" }
        let name: String = c.label.isEmpty ? PadActions.label(c.action) : c.label
        return name + " button, " + PadActions.label(c.action)
    }

    /// Changes one control by id (the accessibility actions and the drag both use it).
    private func change(_ id: UUID, record: Bool = true, _ body: @escaping (inout TouchControlSpec) -> Void) {
        edit(record: record) { t in
            guard let i = t.controls.firstIndex(where: { $0.id == id }) else { return }
            body(&t.controls[i])
        }
    }

    private func nudge(_ id: UUID, dx: Double, dy: Double, grow: Double = 0) {
        selected = id
        change(id) { $0.x += dx; $0.y += dy; $0.size += grow }
    }

    private func drag(_ c: TouchControlSpec, _ v: DragGesture.Value, rect: CGRect) {
        selected = c.id
        let first = dragStart[c.id] == nil
        let start = dragStart[c.id] ?? CGPoint(x: c.x, y: c.y)
        dragStart[c.id] = start
        let nx = Double(start.x + v.translation.width / rect.width)
        let ny = Double(start.y + v.translation.height / rect.height)
        change(c.id, record: first) { $0.x = nx; $0.y = ny }
    }

    private func interactiveMarker(_ c: TouchControlSpec, rect: CGRect, scale: CGFloat) -> some View {
        let id = c.id
        return marker(c, side: CGFloat(c.size) * scale)
            .position(x: CGFloat(c.x) * rect.width, y: CGFloat(c.y) * rect.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibleName(c))
            .accessibilityHint("Drag to move. Use the actions to move or resize it.")
            .accessibilityAddTraits(id == selected ? .isSelected : [])
            .accessibilityAction(named: "Select") { selected = id }
            .accessibilityAction(named: "Move left") { nudge(id, dx: -0.03, dy: 0) }
            .accessibilityAction(named: "Move right") { nudge(id, dx: 0.03, dy: 0) }
            .accessibilityAction(named: "Move up") { nudge(id, dx: 0, dy: -0.03) }
            .accessibilityAction(named: "Move down") { nudge(id, dx: 0, dy: 0.03) }
            .accessibilityAction(named: "Bigger") { nudge(id, dx: 0, dy: 0, grow: 8) }
            .accessibilityAction(named: "Smaller") { nudge(id, dx: 0, dy: 0, grow: -8) }
            .accessibilityAction(named: "Remove") { edit { $0.controls.removeAll { $0.id == id } }; selected = nil }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { drag(c, $0, rect: rect) }
                .onEnded { _ in dragStart[id] = nil })
            .onTapGesture { selected = id }
    }

    private func marker(_ c: TouchControlSpec, side: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(c.id == selected ? 0.38 : 0.2))
            Circle().strokeBorder(c.id == selected ? Theme.accent : Color.white.opacity(0.45), lineWidth: c.id == selected ? 3 : 1.5)
            Text(c.isStick ? (c.action == "stick-arrows" ? "\u{2191}\u{2190}\u{2192}\u{2193}" : "WASD") : c.label)
                .font(.system(size: max(9, side * 0.3), weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.4).padding(4)
        }
        .frame(width: side, height: side)
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let id = selected, let c = layout.controls.first(where: { $0.id == id }) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    if !c.isStick {
                        PadTextField(title: "Label", prompt: "Label", text: Binding(get: { c.label }, set: { v in update(id) { $0.label = v } }))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                        Picker("Does", selection: Binding(get: { c.action }, set: { v in update(id) { $0.action = v; if ["lmb", "rmb", "mmb"].contains(v) { $0.mode = "hold" } } })) {
                            ForEach((PadActions.list + PadActions.touchOnly).filter { $0.id != "none" }, id: \.id) { Text($0.label).tag($0.id) }
                        }.pickerStyle(.menu)
                        if case .key = PadActions.action(c.action) {
                            Picker("Mode", selection: Binding(get: { c.mode == "latch" ? "latch" : "tap" }, set: { v in update(id) { $0.mode = v } })) {
                                Text("Tap or hold").tag("tap"); Text("Latch").tag("latch")
                            }.pickerStyle(.segmented).frame(maxWidth: 200)
                        }
                    } else {
                        Text(c.action == "stick-arrows" ? "Stick: arrow keys" : "Stick: W A S D").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    Button(role: .destructive) { edit { $0.controls.removeAll { $0.id == id } }; selected = nil } label: { Label("Remove", systemImage: "trash") }
                }
                HStack {
                    Text("Size").font(.footnote).foregroundStyle(Theme.textDim)
                    Slider(value: Binding(get: { c.size }, set: { v in update(id) { $0.size = v } }), in: TouchLayout.sizeRange)
                }
            }
            .padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.horizontal, 16)
        } else {
            Text("Drag a control to move it. Tap one to change it. Add more with Add.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 16)
        }
    }

    private func update(_ id: UUID, _ change: (inout TouchControlSpec) -> Void) {
        edit { t in if let i = t.controls.firstIndex(where: { $0.id == id }) { change(&t.controls[i]) } }
    }
}

// MARK: - In the game

/// Opened from the running game's menu: pick the bind set in use (it applies at once), make a new one, edit a set's controller binds and layout, or go and edit
/// the on-screen controls on the game itself. The game keeps running behind it.
struct InGameBindsSheet: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var editing: UUID?
    @State private var showPadBinds = false

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Binds").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "ig-close", title: "Back to the game", symbol: "checkmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    if let g = game {
                        let sets = g.bindSets ?? []
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Changes apply right away, while the game runs. Try a set, then come back and adjust it.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                            if PadInput.keyboardMouseAvailable {
                                SettingsGroup(title: "Controller") {
                                    ToggleRow(id: "ig-padkeys", symbol: "keyboard", title: "Controller as keyboard and mouse",
                                              subtitle: g.activeBindSet?.pad != nil ? "A bind set with controller binds is in use and decides" : nil,
                                              info: "Left stick W A S D, right stick the mouse, buttons as keys. Off goes back to Automatic. Applies at once.",
                                              isOn: Binding(get: { g.engine?.controllerMode == "keys" }, set: { on in
                                                  model.update(g) { var e = $0.engine ?? GameEngine(); e.controllerMode = on ? "keys" : nil; e.padAuto = nil; $0.engine = e.isEmpty ? nil : e } }))
                                    ActionRow(id: "ig-padbinds", symbol: "gamecontroller", title: "Controller buttons",
                                              subtitle: (g.engine?.binds?.isEmpty ?? true) ? "Standard layout; press a button to change it" : "\(g.engine?.binds?.count ?? 0) changed", chevron: true) { showPadBinds = true }
                                }
                            }
                            SettingsGroup(title: "In use") {
                                ChoiceRow(id: "ig-active", symbol: "checkmark.circle.fill", title: "Bind set in use",
                                          options: [(UUID?.none, "Standard")] + sets.map { (Optional($0.id), $0.name) },
                                          selection: Binding(get: { g.activeBindSetID.flatMap { id in sets.contains { $0.id == id } ? id : nil } }, set: { v in model.update(g) { $0.activeBindSetID = v } }))
                                ActionRow(id: "ig-new", symbol: "plus.circle.fill", title: "New bind set from the current controls", chevron: false) { create(g) }
                            }
                            if let active = g.activeBindSet {
                                SettingsGroup(title: active.name) {
                                    ActionRow(id: "ig-edit", symbol: "square.and.pencil", title: "Edit this set", subtitle: "Controller binds and the touch layout", chevron: true) { editing = active.id }
                                    if active.touch != nil {
                                        ActionRow(id: "ig-screen", symbol: "hand.tap.fill", title: "Edit the on-screen controls on the game", subtitle: "Move and change controls while you look at the game, and test them", chevron: false) {
                                            dismiss()
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { GameHUDView.shared.beginLayoutEditing() }
                                        }
                                    }
                                }
                            } else {
                                SettingsGroup {
                                    ActionRow(id: "ig-screen-new", symbol: "hand.tap.fill", title: "Make on-screen controls on the game", subtitle: "Starts a new set with its own layout", chevron: false) {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { GameHUDView.shared.beginLayoutEditing() }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 680).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "ig-close"; scope.focused = "ig-close" }
        .presentationBackground(Theme.background)
        .sheet(isPresented: $showPadBinds) { PadBindsSheet(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
        .sheet(item: Binding(get: { editing.map { EditTarget(id: $0) } }, set: { editing = $0?.id })) { target in
            BindSetEditor(gameID: gameID, setID: target.id).environmentObject(model).preferredColorScheme(Theme.scheme)
        }
    }

    private struct EditTarget: Identifiable { let id: UUID }

    private func create(_ g: Game) {
        var set = BindSet(name: "My binds")
        var n = 2; while (g.bindSets ?? []).contains(where: { $0.name == set.name }) { set.name = "My binds \(n)"; n += 1 }
        if let e = g.engine, e.controllerMode == "keys" { set.pad = PadPart(binds: e.binds ?? [:], mouseVertical: e.padMouseVertical).sanitized() } else { set.pad = PadPart() }
        model.update(g) { $0.bindSets = ($0.bindSets ?? []) + [set]; $0.activeBindSetID = set.id }
        editing = set.id
    }
}
