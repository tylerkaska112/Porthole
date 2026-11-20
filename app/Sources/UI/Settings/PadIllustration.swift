// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A gamepad seen from above, drawn to scale, with each control where it is on the real thing and lit while it is pressed. The sticks show where they are (small: the big dials under it are for
/// judging drift), the triggers fill from the bottom, the D-pad lights the arm that is held. Xbox and Switch pads have the left stick above the D-pad; PlayStation pads have them the other way
/// round, and the picture follows. Nothing here is interactive; it only shows a PadReading.
struct PadIllustration: View {
    let pad: PadReading
    let everPressed: Set<PadButton>

    /// Where things sit, as fractions of the body's width and height.
    private struct Plan {
        var leftStick: CGPoint, dpad: CGPoint, rightStick: CGPoint, face: CGPoint
        static let xbox = Plan(leftStick: CGPoint(x: 0.28, y: 0.36), dpad: CGPoint(x: 0.40, y: 0.65), rightStick: CGPoint(x: 0.60, y: 0.65), face: CGPoint(x: 0.74, y: 0.36))
        static let playStation = Plan(leftStick: CGPoint(x: 0.38, y: 0.65), dpad: CGPoint(x: 0.26, y: 0.38), rightStick: CGPoint(x: 0.62, y: 0.65), face: CGPoint(x: 0.74, y: 0.38))
    }
    private var plan: Plan { pad.kind.isPlayStation ? .playStation : .xbox }

    private let ratio: CGFloat = 1.5            // body width / height
    private let headroom: CGFloat = 0.20        // triggers and shoulders stand above the body, as a share of its height

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w / ratio
            let top = h * headroom
            ZStack(alignment: .topLeading) {
                // The body.
                PadBodyShape()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                    .overlay(PadBodyShape().stroke(Theme.line, lineWidth: 1))
                    .frame(width: w, height: h)
                    .offset(y: top)
                // Triggers and shoulders on top.
                trigger(.left, value: pad.lt, w: w, h: h)
                trigger(.right, value: pad.rt, w: w, h: h)
                shoulder(.lb, x: 0.17, w: w, h: h, top: top)
                shoulder(.rb, x: 0.83, w: w, h: h, top: top)
                // The middle buttons.
                if pad.hasView { small(.view, at: CGPoint(x: 0.43, y: 0.30), w: w, h: h, top: top) }
                small(.menu, at: CGPoint(x: 0.57, y: 0.30), w: w, h: h, top: top)
                if pad.hasHome { small(.home, at: CGPoint(x: 0.50, y: 0.20), w: w, h: h, top: top, big: true) }
                // The sticks.
                stick(x: pad.lx, y: pad.ly, click: .leftStick, at: plan.leftStick, w: w, h: h, top: top)
                stick(x: pad.rx, y: pad.ry, click: .rightStick, at: plan.rightStick, w: w, h: h, top: top)
                // D-pad and face buttons.
                dpad(at: plan.dpad, w: w, h: h, top: top)
                faceButtons(at: plan.face, w: w, h: h, top: top)
            }
            .frame(width: w, height: h + top, alignment: .topLeading)
        }
        .aspectRatio(ratio / (1 + headroom), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pad.name) as drawn")
    }

    // MARK: Parts

    private func point(_ p: CGPoint, w: CGFloat, h: CGFloat, top: CGFloat) -> CGPoint { CGPoint(x: p.x * w, y: top + p.y * h) }

    private func lit(_ b: PadButton) -> Bool { pad.held.contains(b) }
    private func was(_ b: PadButton) -> Bool { everPressed.contains(b) }

    private enum Side { case left, right }

    private func trigger(_ side: Side, value: Float, w: CGFloat, h: CGFloat) -> some View {
        let width = w * 0.115, height = h * headroom * 1.05
        let x = (side == .left ? 0.17 : 0.83) * w
        let shape = UnevenRoundedRectangle(topLeadingRadius: width * 0.5, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: width * 0.5, style: .continuous)
        return ZStack(alignment: .bottom) {
            shape.fill(Theme.panelHigh)
            shape.fill(Theme.accent).frame(height: height * CGFloat(min(max(value, 0), 1)))
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(value > 0.02 ? Theme.accent : Theme.line, lineWidth: 1))
        .position(x: x, y: height / 2)
        .accessibilityHidden(true)
    }

    private func shoulder(_ b: PadButton, x: CGFloat, w: CGFloat, h: CGFloat, top: CGFloat) -> some View {
        let on = lit(b)
        return Text(PadNames.name(b, kind: pad.kind))
            .font(.system(size: max(9, w * 0.033), weight: .bold, design: .rounded)).foregroundStyle(on ? Theme.onAccent : Theme.textDim)
            .frame(width: w * 0.26, height: h * 0.085)
            .background(on ? Theme.accent : Theme.panelHigh, in: Capsule())
            .overlay(Capsule().stroke(was(b) ? Theme.accent : Theme.line, lineWidth: was(b) ? 1.5 : 1))
            .position(x: x * w, y: top + h * 0.035)
    }

    private func small(_ b: PadButton, at p: CGPoint, w: CGFloat, h: CGFloat, top: CGFloat, big: Bool = false) -> some View {
        let on = lit(b), d = w * (big ? 0.065 : 0.05)
        return Circle().fill(on ? Theme.accent : Theme.panelHigh).frame(width: d, height: d)
            .overlay(Circle().stroke(was(b) ? Theme.accent : Theme.line, lineWidth: was(b) ? 1.5 : 1))
            .position(point(p, w: w, h: h, top: top))
    }

    private func stick(x: Float, y: Float, click: PadButton, at p: CGPoint, w: CGFloat, h: CGFloat, top: CGFloat) -> some View {
        let r = w * 0.095, travel = r * 0.62
        let on = lit(click)
        return ZStack {
            Circle().fill(Color.black.opacity(0.28)).frame(width: r * 2, height: r * 2)
            Circle().stroke(on ? Theme.accent : (was(click) ? Theme.accent.opacity(0.7) : Theme.line), lineWidth: on ? 3 : (was(click) ? 2 : 1)).frame(width: r * 2, height: r * 2)
            Circle().fill(on ? Theme.accent : Theme.panelHigh.opacity(1.6)).frame(width: r * 1.15, height: r * 1.15)
                .overlay(Circle().stroke(Theme.text.opacity(0.5), lineWidth: 1))
                .offset(x: CGFloat(x) * travel, y: -CGFloat(y) * travel)
        }
        .position(point(p, w: w, h: h, top: top))
    }

    private func dpad(at p: CGPoint, w: CGFloat, h: CGFloat, top: CGFloat) -> some View {
        let arm = w * 0.052, gap = arm * 0.95
        func piece(_ b: PadButton, dx: CGFloat, dy: CGFloat, horizontal: Bool) -> some View {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(lit(b) ? Theme.accent : Theme.panelHigh)
                .frame(width: horizontal ? arm * 1.15 : arm, height: horizontal ? arm : arm * 1.15)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(was(b) ? Theme.accent : Theme.line, lineWidth: was(b) ? 1.5 : 1))
                .offset(x: dx, y: dy)
        }
        return ZStack {
            Rectangle().fill(Theme.panelHigh).frame(width: arm, height: arm)
            piece(.up, dx: 0, dy: -gap, horizontal: false); piece(.down, dx: 0, dy: gap, horizontal: false)
            piece(.left, dx: -gap, dy: 0, horizontal: true); piece(.right, dx: gap, dy: 0, horizontal: true)
        }
        .position(point(p, w: w, h: h, top: top))
    }

    private func faceButtons(at p: CGPoint, w: CGFloat, h: CGFloat, top: CGFloat) -> some View {
        let d = w * 0.072, spread = w * 0.062
        func button(_ b: PadButton, dx: CGFloat, dy: CGFloat) -> some View {
            let on = lit(b)
            return Text(PadNames.name(b, kind: pad.kind))
                .font(.system(size: max(9, d * 0.42), weight: .bold, design: .rounded)).foregroundStyle(on ? Theme.onAccent : Theme.text)
                .frame(width: d, height: d)
                .background(on ? Theme.accent : Theme.panelHigh, in: Circle())
                .overlay(Circle().stroke(was(b) ? Theme.accent : Theme.line, lineWidth: was(b) ? 1.5 : 1))
                .offset(x: dx, y: dy)
        }
        return ZStack {
            button(.y, dx: 0, dy: -spread); button(.a, dx: 0, dy: spread)
            button(.x, dx: -spread, dy: 0); button(.b, dx: spread, dy: 0)
        }
        .position(point(p, w: w, h: h, top: top))
    }
}

/// The outline of the pad: a wide body with two rounded grips.
struct PadBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: p(0.15, 0.08))
        path.addQuadCurve(to: p(0.85, 0.08), control: p(0.50, 0.00))
        path.addCurve(to: p(0.985, 0.42), control1: p(0.95, 0.08), control2: p(0.99, 0.22))
        path.addCurve(to: p(0.855, 0.985), control1: p(1.0, 0.68), control2: p(0.95, 0.99))
        path.addCurve(to: p(0.70, 0.76), control1: p(0.76, 0.98), control2: p(0.72, 0.90))
        path.addQuadCurve(to: p(0.30, 0.76), control: p(0.50, 0.69))
        path.addCurve(to: p(0.145, 0.985), control1: p(0.28, 0.90), control2: p(0.24, 0.98))
        path.addCurve(to: p(0.015, 0.42), control1: p(0.05, 0.99), control2: p(0.0, 0.68))
        path.addCurve(to: p(0.15, 0.08), control1: p(0.01, 0.22), control2: p(0.05, 0.08))
        path.closeSubpath()
        return path
    }
}
