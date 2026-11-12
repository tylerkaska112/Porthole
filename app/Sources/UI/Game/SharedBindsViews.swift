// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Shared bind sets inside a game's page: browse what other people shared for this game, read the reviews, add one to your own sets, rate it, and share your own.
// A downloaded set is an ordinary local set; it is never put in use by itself.

// MARK: - Browse

struct SharedBindsBrowser: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = BindsShareStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var sort = "top"
    @State private var items: [SharedBind] = []
    @State private var loading = false
    @State private var error: String?
    @State private var gameKey: String?
    @State private var unidentified = false
    @State private var opened: SharedBind?

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Shared binds").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "sb-close", title: "Done", symbol: "checkmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Controller binds and touch layouts other people shared for \(game?.name ?? "this game"). Adding one puts a copy in your sets; it is only used when you pick it.")
                            .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                        SettingsGroup {
                            ChoiceRow(id: "sb-sort", symbol: "arrow.up.arrow.down", title: "Sort by", options: [("top", "Best rated"), ("downloads", "Most downloaded"), ("new", "Newest")],
                                      selection: Binding(get: { sort }, set: { sort = $0; Task { await load() } }))
                        }
                        SettingsGroup {
                            if let error { Text(error).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
                            if loading && items.isEmpty { HStack { ProgressView(); Text("Looking\u{2026}").foregroundStyle(Theme.textDim) }.padding(.horizontal, 6) }
                            ForEach(items) { item in
                                ActionRow(id: "sb-\(item.id)", symbol: item.hasTouch && item.hasPad ? "keyboard.badge.ellipsis" : item.hasTouch ? "hand.tap.fill" : "gamecontroller.fill",
                                          title: item.displayName, subtitle: item.contents, detail: ratingText(item)) { opened = item }
                            }
                            if items.isEmpty && !loading && error == nil {
                                Text(unidentified ? "Porthole can't tell which game this is yet, so there is nothing to look up." : "Nobody has shared binds for this game yet. Be the first from one of your own sets.")
                                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                            }
                        }
                    }
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "sb-close"; scope.focused = "sb-close" }
        .task { await load() }
        .presentationBackground(Theme.background)
        .sheet(item: $opened) { item in SharedBindDetailSheet(gameID: gameID, summary: item).environmentObject(model).preferredColorScheme(Theme.scheme) }
    }

    private func ratingText(_ item: SharedBind) -> String {
        let votes = item.up + item.down
        let rating = votes == 0 ? "No ratings" : "\(Int((item.approval ?? 0) * 100))% (\(votes))"
        return item.downloads > 0 ? "\(rating) \u{00B7} \(item.downloads) added" : rating
    }

    private func load() async {
        guard store.available else { error = "This build is not connected to a community server, so shared binds are not available."; return }
        guard let game else { return }
        loading = true; error = nil
        defer { loading = false }
        if gameKey == nil { gameKey = await store.gameRef(for: game)?.id }
        guard let key = gameKey else { unidentified = true; items = []; return }
        do { items = try await store.list(gameID: key, sort: sort) }
        catch { self.error = ErrorText.plain(error) }
    }
}

// MARK: - One shared set

struct SharedBindDetailSheet: View {
    let gameID: UUID
    let summary: SharedBind
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = BindsShareStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var detail: SharedBind?
    @State private var reviews: [SharedBindReview] = []
    @State private var message: String?
    @State private var busy = false
    @State private var reviewing = false
    @State private var confirmFlag = false

    private var game: Game? { model.games.first { $0.id == gameID } }
    private var shown: SharedBind { detail ?? summary }
    private var alreadyAdded: Bool { game?.bindSets?.contains { $0.downloadedFrom == summary.id } == true }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(shown.displayName).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                    PillButton(id: "sd-close", title: "Done", symbol: "checkmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsGroup(title: "About") {
                            ValueRow(id: "sd-contents", symbol: "square.stack.3d.up.fill", title: "Contains", value: shown.contents)
                            ValueRow(id: "sd-rating", symbol: "hand.thumbsup.fill", title: "Rating", value: shown.approval.map { "\(Int($0 * 100))% of \(shown.up + shown.down)" } ?? "Not rated yet")
                            ValueRow(id: "sd-adds", symbol: "arrow.down.circle.fill", title: "Added by", value: "\(shown.downloads)")
                            ValueRow(id: "sd-updated", symbol: "clock.fill", title: "Updated", value: shown.updated)
                            if let notes = shown.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                            else { Text("The author's name and notes show here once they have been approved.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                        }
                        SettingsGroup(title: "Use it") {
                            ActionRow(id: "sd-add", symbol: alreadyAdded ? "checkmark.circle.fill" : "plus.circle.fill", title: alreadyAdded ? "Already in your sets" : "Add to my sets",
                                      subtitle: "A copy you can change. It is not used until you pick it.", chevron: false) { add() }
                            if let message { Text(message).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                        }
                        if let d = detail { preview(d) }
                        SettingsGroup(title: "Reviews") {
                            ActionRow(id: "sd-up", symbol: "hand.thumbsup", title: "Rate it", subtitle: "Thumbs up or down, and an optional comment", chevron: true) { reviewing = true }
                            ForEach(reviews) { r in
                                RowBase(id: "rv-\(r.id)", symbol: r.thumb == "up" ? "hand.thumbsup.fill" : "hand.thumbsdown.fill", tint: r.thumb == "up" ? .green : .red, title: r.comment.isEmpty ? (r.thumb == "up" ? "Thumbs up" : "Thumbs down") : r.comment, subtitle: r.date, action: {}) { EmptyView() }
                            }
                            if reviews.isEmpty { Text("No comments yet.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                        }
                        SettingsGroup {
                            ActionRow(id: "sd-flag", symbol: "flag", title: "Report this set", subtitle: "If it is spam or not what it says. Several reports hide it.", chevron: false) { confirmFlag = true }
                        }
                    }
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "sd-close"; scope.focused = "sd-close" }
        .task { await load() }
        .presentationBackground(Theme.background)
        .sheet(isPresented: $reviewing) { SharedBindReviewSheet(setID: summary.id) { result in
            message = result.commentStatus == "pending" ? "Thanks. Your comment shows once it has been approved." : "Thanks for rating it."
            Task { await load() }
        }.preferredColorScheme(Theme.scheme) }
        .confirm("Report this set?", message: "Use this for spam or sets that are not what they say.", confirmTitle: "Report", destructive: true, isPresented: $confirmFlag) {
            Task { do { try await store.flag(id: summary.id); message = "Reported. Thank you." } catch { message = ErrorText.plain(error) } }
        }
    }

    @ViewBuilder private func preview(_ d: SharedBind) -> some View {
        if let pad = d.pad {
            SettingsGroup(title: "Controller") {
                let merged = PadActions.bindings(pad.binds)
                ValueRow(id: "sd-ls", symbol: "l.joystick.fill", title: "Left stick", value: PadActions.stickModes.first { $0.id == (pad.binds["LS"] ?? "wasd") }?.label ?? "")
                ValueRow(id: "sd-rs", symbol: "r.joystick.fill", title: "Right stick", value: PadActions.stickModes.first { $0.id == (pad.binds["RS"] ?? "mouse") }?.label ?? "")
                ForEach(PadActions.buttons.filter { pad.binds[$0] != nil }, id: \.self) { name in
                    ValueRow(id: "sd-b-\(name)", symbol: "circle.circle", title: name, value: PadActions.label(merged[name] ?? "none"))
                }
                if pad.binds.filter({ PadActions.buttons.contains($0.key) }).isEmpty { Text("The standard button layout.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
        }
        if let touch = d.touch {
            SettingsGroup(title: "Touch layout") {
                TouchLayoutPreview(layout: touch).frame(height: 190).padding(.vertical, 4)
            }
        }
    }

    private func load() async {
        async let d = try? store.detail(id: summary.id)
        async let r = try? store.reviews(id: summary.id)
        if let loaded = await d { detail = loaded }
        reviews = await r ?? []
    }

    private func add() {
        guard let g = game, let d = detail else { message = "Still loading. Try again in a moment."; return }
        if alreadyAdded { message = "That set is already in your list."; return }
        guard let set = BindsShare.localSet(from: d, existingNames: (g.bindSets ?? []).map(\.name)) else { message = "That set has nothing usable in it."; return }
        model.update(g) { $0.bindSets = ($0.bindSets ?? []) + [set] }
        message = "Added as \u{201C}\(set.name)\u{201D}. Pick it under Bind set in use when you want it."
        Task { await store.countDownload(id: d.id) }
    }
}

/// A read-only sketch of a touch layout.
struct TouchLayoutPreview: View {
    let layout: TouchLayout
    var body: some View {
        GeometryReader { geo in
            let aspect = CGFloat(max(LaunchSettings.screenAspect, 1.2))
            let w = min(geo.size.width, geo.size.height * aspect), h = w / aspect
            let scale = w / max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85)).frame(width: w, height: h)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                ForEach(layout.controls) { c in
                    let side = CGFloat(c.size) * scale
                    ZStack {
                        Circle().fill(Color.white.opacity(0.22)); Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                        Text(c.faceText)
                            .font(.system(size: max(7, side * 0.3), weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.4).padding(2)
                    }
                    .frame(width: side, height: side).position(x: CGFloat(c.x) * w, y: CGFloat(c.y) * h)
                }
            }
            .frame(width: w, height: h).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Rate a set

struct SharedBindReviewSheet: View {
    let setID: Int
    let onDone: (BindReviewResult) -> Void
    @ObservedObject private var store = BindsShareStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var thumbUp = true
    @State private var comment = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Rate this set").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "rs-close", title: "Cancel", symbol: "xmark") { dismiss() }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsGroup {
                            ChoiceRow(id: "rs-thumb", symbol: "hand.thumbsup.fill", title: "Did it work for you?", options: [(true, "Thumbs up"), (false, "Thumbs down")], selection: $thumbUp)
                            TextFieldRow(id: "rs-comment", symbol: "text.bubble", title: "Comment", placeholder: "optional (300 characters)", text: Binding(get: { comment }, set: { comment = String($0.prefix(300)) }))
                            Text("A comment is shown to others only after it has been approved. Your thumb counts at once. Rating again replaces your earlier rating.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                        }
                        SettingsGroup {
                            ActionRow(id: "rs-send", symbol: "paperplane.fill", title: sending ? "Sending\u{2026}" : "Send", chevron: false, prominent: true) { send() }
                            if let error { Text(error).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
                        }
                    }
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "rs-thumb"; scope.focused = "rs-thumb" }
        .presentationBackground(Theme.background)
    }

    private func send() {
        guard !sending else { return }
        sending = true; error = nil
        Task {
            do { let r = try await store.review(id: setID, thumbUp: thumbUp, comment: comment); sending = false; onDone(r); dismiss() }
            catch { sending = false; self.error = ErrorText.plain(error) }
        }
    }
}

// MARK: - Sharing one of your sets (inside the set editor)

struct BindSetSharingGroup: View {
    let gameID: UUID
    let setID: UUID
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = BindsShareStore.shared
    @State private var message: String?
    @State private var busy = false
    @State private var confirmShare = false
    @State private var confirmStop = false

    private var game: Game? { model.games.first { $0.id == gameID } }
    private var set: BindSet? { game?.bindSets?.first { $0.id == setID } }

    var body: some View {
        if let g = game, let s = set {
            let remote = s.remoteID.flatMap { store.mine[$0] }
            SettingsGroup(title: "Community") {
                if let remote {
                    ValueRow(id: "sh-state", symbol: "person.2.fill", title: "Shared", value: remote.hidden ? "Hidden" : "Yes")
                    Text("\(remote.statusText). \(remote.up) up, \(remote.down) down, added by \(remote.downloads).").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                    ActionRow(id: "sh-update", symbol: "arrow.triangle.2.circlepath", title: "Update the shared copy", subtitle: "Sends this version. Changed text waits for approval again.", chevron: false) { confirmShare = true }
                    ActionRow(id: "sh-stop", symbol: "person.2.slash", title: "Stop sharing", destructive: true, chevron: false) { confirmStop = true }
                } else {
                    ActionRow(id: "sh-share", symbol: "square.and.arrow.up.on.square", title: "Share this set", subtitle: "Anyone with Porthole can find it for this game",
                              info: "Shares the controller binds and the touch layout so other people can add them. The name, notes and control labels you typed are shown to others only after they have been approved. No account or name of yours is sent.", chevron: false) { confirmShare = true }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
            .task { if store.available { await store.refreshMine() } }
            .confirm(remote == nil ? "Share \u{201C}\(s.name)\u{201D}?" : "Update the shared copy?", message: "Everyone using Porthole can see its binds and layout. Its name, notes and control labels appear after approval. You can stop sharing at any time.",
                     confirmTitle: remote == nil ? "Share" : "Update", isPresented: $confirmShare) { share(g, s) }
            .confirm("Stop sharing?", message: "The shared copy is removed with its ratings. Your own set stays.", confirmTitle: "Stop sharing", destructive: true, isPresented: $confirmStop) { stop(g, s) }
        }
    }

    private func share(_ g: Game, _ s: BindSet) {
        guard !busy else { return }
        if let why = BindsShare.problem(sharing: s) { message = why; return }
        guard store.available else { message = "This build is not connected to a community server, so sharing is not available."; return }
        busy = true; message = "Sharing\u{2026}"
        Task {
            do {
                let result = try await store.publish(s, for: g)
                model.update(g) { guard var sets = $0.bindSets, let i = sets.firstIndex(where: { $0.id == s.id }) else { return }; sets[i].remoteID = result.id; $0.bindSets = sets }
                message = result.textStatus == "pending" ? "Shared. The name and notes show after they have been approved." : "Shared."
            } catch { message = ErrorText.plain(error) }
            busy = false
        }
    }

    private func stop(_ g: Game, _ s: BindSet) {
        guard let id = s.remoteID, !busy else { return }
        busy = true
        Task {
            do {
                try await store.unpublish(remoteID: id)
                model.update(g) { guard var sets = $0.bindSets, let i = sets.firstIndex(where: { $0.id == s.id }) else { return }; sets[i].remoteID = nil; $0.bindSets = sets }
                message = "No longer shared."
            } catch { message = ErrorText.plain(error) }
            busy = false
        }
    }
}
