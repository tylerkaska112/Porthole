// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import Observation

/// One colour scheme: a deep background, glass surfaces, and the two colours the glow is made of.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let bgTop: UInt32, bgBottom: UInt32
    let accent: UInt32, accent2: UInt32
    /// What drifts behind the screens (holiday schemes only).
    var decor: Decor = .none

    /// The built-in schemes. The first is the default.
    static let presets: [Palette] = [
        // Slate-blue like Steam's own screens, with Porthole's cyan-to-violet light on top.
        Palette(id: "deepsea", name: "Deep Sea", bgTop: 0x1B2838, bgBottom: 0x0B121B, accent: 0x4CB8F5, accent2: 0x7A6CFF),
        Palette(id: "aurora", name: "Aurora", bgTop: 0x0A1D1C, bgBottom: 0x050F12, accent: 0x3DDC97, accent2: 0x4CC9F0),
        Palette(id: "sunset", name: "Sunset", bgTop: 0x25122B, bgBottom: 0x120A18, accent: 0xFF8A5B, accent2: 0xFF4D8D),
        Palette(id: "ember", name: "Ember", bgTop: 0x2A1210, bgBottom: 0x130909, accent: 0xFF5A4F, accent2: 0xFFB020),
        Palette(id: "orchid", name: "Orchid", bgTop: 0x1D1233, bgBottom: 0x0D0817, accent: 0xC77DFF, accent2: 0x5AC8FA),
        Palette(id: "graphite", name: "Graphite", bgTop: 0x1B1D22, bgBottom: 0x0B0C0F, accent: 0xE5E7EB, accent2: 0x8B93A1),
    ]

    /// A scheme made from one colour the person picked: the background takes its hue, the second glow colour sits a little further round the colour wheel.
    static func custom(accent hex: UInt32) -> Palette {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        func hexOf(_ hue: CGFloat, _ sat: CGFloat, _ bri: CGFloat) -> UInt32 {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            UIColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: sat, brightness: bri, alpha: 1).getRed(&r, green: &g, blue: &bl, alpha: &al)
            return UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(bl * 255)
        }
        return Palette(id: "custom", name: "Custom", bgTop: hexOf(h, min(0.55, max(s, 0.25)), 0.19), bgBottom: hexOf(h, min(0.6, max(s, 0.25)), 0.09),
                       accent: hex, accent2: hexOf(h + 0.09, min(max(s, 0.45), 0.9), max(b, 0.85)))
    }
}

/// How strong the glow around the selected thing is.
enum GlowLevel: String, CaseIterable, Identifiable {
    case off, soft, strong
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .soft: "Soft"; case .strong: "Strong" } }
    var strength: Double { switch self { case .off: 0; case .soft: 0.6; case .strong: 1 } }
}

/// The app's look, chosen by the person: a colour scheme (or their own accent colour), how strong the glow is, and whether the background moves.
@Observable
final class ThemeStore {
    nonisolated(unsafe) static let shared = ThemeStore()

    private let defaults: UserDefaults
    /// Goes up whenever the look changes; the root view uses it to redraw everything.
    private(set) var revision = 0

    var presetID: String { didSet { defaults.set(presetID, forKey: "f4.themePreset"); revision += 1 } }
    var customAccent: UInt32 { didSet { defaults.set(Int(customAccent), forKey: "f4.themeCustom"); revision += 1 } }
    var glow: GlowLevel { didSet { defaults.set(glow.rawValue, forKey: "f4.glow"); revision += 1 } }
    /// True while any list is being scrolled: the moving background rests meanwhile (not saved, and it does not restyle anything).
    var scrolling = false
    var animatedBackground: Bool { didSet { defaults.set(animatedBackground, forKey: "f4.animatedBackground"); revision += 1 } }
    /// Dress up for holidays by the date (see `Season`); the person's own scheme is back when the holiday ends.
    var festive: Bool { didSet { defaults.set(festive, forKey: "f4.festive"); revision += 1 } }
    /// Shows a holiday's look out of season, to see it (not saved).
    var previewSeason: Season? { didSet { revision += 1 } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        glow = GlowLevel(rawValue: defaults.string(forKey: "f4.glow") ?? "") ?? .strong
        animatedBackground = defaults.object(forKey: "f4.animatedBackground") as? Bool ?? true
        festive = defaults.object(forKey: "f4.festive") as? Bool ?? true
        customAccent = UInt32(defaults.object(forKey: "f4.themeCustom") as? Int ?? 0x4CC9F0)
        if let preset = defaults.string(forKey: "f4.themePreset") {
            presetID = preset
        } else if let old = defaults.string(forKey: "f4.accentColor"), let hex = Self.legacyAccents[old] {
            // The previous look had six flat accent colours; keep the one the person had.
            presetID = "custom"; customAccent = hex
        } else {
            presetID = Palette.presets[0].id
        }
    }

    private static let legacyAccents: [String: UInt32] = ["blue": 0x3B82F6, "indigo": 0x6366F1, "teal": 0x14B8A6, "green": 0x22C55E, "orange": 0xF97316, "pink": 0xEC4899]

    /// The holiday the app is dressed for right now: the one being previewed, else today's when Festive themes is on.
    var activeSeason: Season? { previewSeason ?? (festive ? Season.active() : nil) }

    var palette: Palette {
        if let season = activeSeason { return season.palette }
        if presetID == "custom" { return Palette.custom(accent: customAccent) }
        return Palette.presets.first { $0.id == presetID } ?? Season.allCases.map(\.palette).first { $0.id == presetID } ?? Palette.presets[0]
    }
}

enum Theme {
    private static func dynamic(dark: @escaping @autoclosure () -> UInt32, light: @escaping @autoclosure () -> UInt32, darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(uiColor: UIColor { t in
            let isDark = t.userInterfaceStyle == .dark
            let hex = isDark ? dark() : light()
            let alpha = isDark ? darkAlpha : lightAlpha
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }
    private static var palette: Palette { ThemeStore.shared.palette }

    // Surfaces. The glass cards are see-through so the glowing background shows a little through them.
    static var backgroundTop: Color { dynamic(dark: palette.bgTop, light: 0xF3F6FC) }
    static var backgroundBottom: Color { dynamic(dark: palette.bgBottom, light: 0xE8EDF8) }
    /// A page background: the same deep gradient the frame draws, so screens that paint their own background still match it.
    static var background: LinearGradient { LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var panel: Color { dynamic(dark: 0xC7D5E0, light: 0xFFFFFF, darkAlpha: 0.075, lightAlpha: 0.78) }
    static var panelHigh: Color { dynamic(dark: 0xC7D5E0, light: 0x101828, darkAlpha: 0.14, lightAlpha: 0.08) }
    static var line: Color { dynamic(dark: 0xC7D5E0, light: 0x101828, darkAlpha: 0.14, lightAlpha: 0.10) }
    static var text: Color { dynamic(dark: 0xF1F5F9, light: 0x101828) }
    static var textDim: Color { dynamic(dark: 0x9DB0C3, light: 0x5B6475) }
    static var good: Color { dynamic(dark: 0x34D399, light: 0x15803D) }
    static var warn: Color { dynamic(dark: 0xFBBF24, light: 0xB45309) }
    static var bad: Color { dynamic(dark: 0xFB7185, light: 0xBE123C) }
    /// Text and icons that sit on top of the accent colour.
    static var onAccent: Color { Color(hex: 0x06101F) }

    static var accent: Color { Color(hex: palette.accent) }
    static var accent2: Color { Color(hex: palette.accent2) }
    static var accentDim: Color { accent.opacity(0.45) }
    /// The signature gradient: used for the glow ring, the Play button and highlights.
    static var accentGradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing) }
    /// The app is dark only: one accent colour is the choice, not light or dark.
    static var scheme: ColorScheme? { .dark }
    static var glowStrength: Double { ThemeStore.shared.glow.strength }

    /// A small section heading.
    static func label(_ s: String) -> some View {
        Text(s).font(.footnote.weight(.semibold)).foregroundStyle(textDim).textCase(.uppercase).tracking(0.6)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A glass surface: a faint fill, a soft top highlight and a hairline edge.
struct PanelStyle: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                LinearGradient(colors: [Theme.line.opacity(1.4), Theme.line.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}
extension View { func panel(radius: CGFloat = 18) -> some View { modifier(PanelStyle(radius: radius)) } }

/// The main action button, for places that still use a plain button style: a glowing accent capsule.
struct PlayButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.onAccent.opacity(enabled ? 1 : 0.6))
            .padding(.vertical, 10).padding(.horizontal, 22)
            .background(enabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.accentDim), in: Capsule())
            .shadow(color: Theme.accent.opacity(enabled ? 0.45 * Theme.glowStrength : 0), radius: 12, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A small status pill: coloured dot and a short label.
struct StatusChip: View {
    let dot: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7).shadow(color: dot.opacity(0.8), radius: 3)
            Text(text).font(.footnote.weight(.medium)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.panel, in: Capsule())
    }
}
