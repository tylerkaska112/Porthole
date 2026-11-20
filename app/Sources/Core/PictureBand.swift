// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreGraphics
import Foundation

/// Where the game's picture goes on the screen. Usually it is fitted into the screen and centred. On an iPad, while the on-screen controls are in use, it goes up to the top edge instead, so the
/// controls get a band of their own under it and cover as little of the picture as possible: the whole picture stays on the screen, only moved.
///
/// An iPad is the only screen this helps: a phone is wider than the picture, so there is nothing under it to move into. Mouse and keyboard, or a real controller, leave the picture where it was.
/// Where a layout of the person's own wants the game's picture: set in the layout editor, so the buttons can be planned around where the game will be. The picture keeps its shape and is never
/// cropped; this only says which corner, edge or middle of the screen it sits against, and how much of the room it takes.
struct PicturePlacement: Codable, Equatable {
    /// 0 against the left edge, 0.5 in the middle, 1 against the right edge.
    var across: Double = 0.5
    /// 0 against the top edge, 0.5 in the middle, 1 against the bottom edge.
    var down: Double = 0.5
    /// How much of the room the picture takes: 1 is as big as it fits.
    var scale: Double = 1

    static let scales: [Double] = [1, 0.9, 0.8, 0.7, 0.6, 0.5]
    static let scaleRange = 0.5...1.0

    init(across: Double = 0.5, down: Double = 0.5, scale: Double = 1) { self.across = across; self.down = down; self.scale = scale }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        across = try c.decodeIfPresent(Double.self, forKey: .across) ?? 0.5
        down = try c.decodeIfPresent(Double.self, forKey: .down) ?? 0.5
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }
    enum CodingKeys: String, CodingKey { case across, down, scale }

    /// A shared file may hold anything: the position is one of the three on each axis, the size within range.
    func sanitized() -> PicturePlacement {
        func third(_ v: Double) -> Double { !v.isFinite ? 0.5 : (v < 0.25 ? 0 : (v > 0.75 ? 1 : 0.5)) }
        let s = scale.isFinite ? min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 1
        return PicturePlacement(across: third(across), down: third(down), scale: (s * 100).rounded() / 100)
    }
}

enum PictureBand {
    /// The least free height under the picture (below the corner margin) for the move to be worth it: a smaller band would make the controls cover the picture anyway.
    static let minimum: CGFloat = 130

    /// An iPad's screen has rounded corners, which cut off the corners of a picture that sits against the top edge and the sides. Moving the picture down by about the corner's radius puts its corners
    /// on the straight part of the edge, where nothing is cut. (The radius differs a little between iPads and the system does not say; this is the usual size.)
    static let padCornerInset: CGFloat = 20

    /// A picture squarer than this (4:3, 5:4) is left filling the screen when nothing else is asked: not many games run that shape any more, and one that does is meant to be played full screen,
    /// even if the controls cover part of it. 16:10 and wider can go up.
    static let narrowest: CGFloat = 1.5

    /// Settings > Controls: on by default.
    static let settingKey = "f4.pictureUp"
    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// The picture fitted into `screen` (the whole picture, never cropped): centred, or against the top edge when `up`.
    static func fit(screen: CGSize, guest: CGSize, up: Bool, cornerInset: CGFloat = 0) -> CGRect {
        fit(screen: screen, guest: guest, placement: PicturePlacement(down: up ? 0 : 0.5), cornerInset: cornerInset)
    }

    /// The picture fitted into `screen` where a layout wants it. With a `cornerInset` (the screen's rounded corners), a picture that reaches a side edge is kept that far from the top or bottom edge,
    /// as far as there is room, so its corners are not cut off.
    static func fit(screen: CGSize, guest: CGSize, placement p: PicturePlacement, cornerInset r: CGFloat = 0) -> CGRect {
        guard guest.width > 0, guest.height > 0, screen.width > 0, screen.height > 0 else { return CGRect(origin: .zero, size: screen) }
        let p = p.sanitized()
        let s = min(screen.width / guest.width, screen.height / guest.height) * CGFloat(p.scale)
        let size = CGSize(width: guest.width * s, height: guest.height * s)
        let x = (screen.width - size.width) * CGFloat(p.across)
        var y = (screen.height - size.height) * CGFloat(p.down)
        let room = max(0, screen.height - size.height)
        if r > 0, x < r || x + size.width > screen.width - r {
            if y < r { y = min(r, room) }
            else if y + size.height > screen.height - r { y = max(screen.height - r - size.height, 0) }
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Whether the picture goes up on its own: on an iPad held sideways, with on-screen controls showing, the setting on, a picture wide enough to leave room, and at least `minimum` free under it.
    static func applies(screen: CGSize, guest: CGSize, isPad: Bool, controlsOn: Bool, enabled: Bool) -> Bool {
        guard isPad, enabled, controlsOn, screen.width > screen.height, guest.width > 0, guest.height > 0, guest.width / guest.height >= narrowest else { return false }
        return screen.height - fit(screen: screen, guest: guest, up: true, cornerInset: padCornerInset).maxY >= minimum
    }

    /// Where the picture is, all things considered. A placement a layout asks for is kept on any screen and for any shape of picture (a 4:3 game too), while that layout's controls are showing;
    /// without one the picture goes up on its own where `applies` says so, and stays filling the screen otherwise.
    static func rect(screen: CGSize, guest: CGSize, placement: PicturePlacement?, isPad: Bool, controlsOn: Bool, enabled: Bool) -> CGRect {
        let corner = isPad ? padCornerInset : 0
        guard controlsOn else { return fit(screen: screen, guest: guest, up: false) }
        if let placement { return fit(screen: screen, guest: guest, placement: placement, cornerInset: corner) }
        return fit(screen: screen, guest: guest, up: applies(screen: screen, guest: guest, isPad: isPad, controlsOn: controlsOn, enabled: enabled), cornerInset: corner)
    }
}
