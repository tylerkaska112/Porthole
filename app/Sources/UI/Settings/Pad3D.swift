// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import SceneKit
import GameController

/// Which 3D controller to show for which controller, and what it can do.
enum PadModel3D: String {
    case dualSense, dualShock4, xbox

    /// The 3D model for a controller kind, or nil for one that has no model (it keeps the flat drawing).
    static func model(for kind: ControllerKind) -> PadModel3D? {
        switch kind {
        case .dualSense: .dualSense
        case .dualShock: .dualShock4
        case .xbox: .xbox
        default: nil
        }
    }

    /// File name of the model and its description in the app's Models folder.
    var base: String { switch self { case .dualSense: "DualSense"; case .dualShock4: "DualShock4"; case .xbox: "Xbox" } }
    /// The name of the model's root in its file.
    var root: String { self == .dualSense ? "DualSense" : "Pad" }
    /// Whether the real controller has motion sensors (the PlayStation pads do; an Xbox pad does not).
    var hasMotion: Bool { self != .xbox }
}

/// A controller as a 3D model that moves with the real one: the sticks tilt, the buttons sink and light up, the triggers swing. Used by Settings > Controls > Test controller for the DualSense (PS5),
/// the DualShock 4 (PS4) and the Xbox pad.
///
/// The models are other people's work under Creative Commons Attribution 4.0, changed by tools/dualsense/prepare_*.py (see app/Models/*-LICENSE.txt and CREDITS.md; the credits are in Settings > About >
/// Licences): "Playstation 5 Dualsense" by AHarmlessPotato, "DualShock 4 PlayStation Controller" by shaielwolf, "Xbox Controller" by umkhero. Each is millimetres with Z up, the pad's top toward +Z, its front toward +Y. Every part that moves is a node of its own, named as the script names
/// it, whose origin is the pivot it turns or sinks about, so a part is moved by changing its transform about its own origin. What does not move is `static_<material>`.
@MainActor final class PadRig3D {
    /// The whole pad, turned to SceneKit's Y-up and scaled to 16 units across. Add `root` to a scene.
    let root = SCNNode()
    private var parts: [String: SCNNode] = [:]
    private var rest: [String: simd_float4x4] = [:]
    private var materials: [String: [SCNMaterial]] = [:]
    /// What each material of a part showed for emission before it was lit (the model's own emission map for some), so it can go back.
    private var restEmission: [String: [Any?]] = [:]
    private var images: [String: UIImage] = [:]
    private var description: Description?
    private let model: PadModel3D
    /// Which part is which control: "ls" "rs" (sticks), "a" "b" "x" "y" (face buttons, bottom, right, left, top), "up" "down" "left" "right" (a d-pad of four keys, or all the same part: one cross that tilts),
    /// "lb" "rb" "lt" "rt", "home" "view" "menu". A model's own description can say otherwise; this is the DualSense's, which the DualShock 4 shares.
    private var roles: [String: String] = ["ls": "stick_l", "rs": "stick_r", "a": "cross", "b": "circle", "x": "square", "y": "triangle", "up": "dpad_up", "down": "dpad_down", "left": "dpad_left", "right": "dpad_right",
                                       "lb": "l1", "rb": "r1", "lt": "l2", "rt": "r2", "home": "ps", "view": "create", "menu": "options"]
    /// Symbols drawn on the buttons' caps (part -> "cross", "circle", "square", "triangle", "up", "down", "left", "right"), for a model whose caps do not carry them.
    private var decals: [String: String] = [:]
    /// Turns the whole pad as the controller is turned (in the pad's own axes, z up).
    private let spin = SCNNode()

    /// DualSense.json: each part's materials in slot order, and each material's textures.
    private struct Description: Decodable {
        struct Cap: Decodable { var x: Float; var y: Float; var z: Float; var normal: [Float]; var radius: Float }
        struct Part: Decodable { var materials: [String]; var cap: Cap? }
        struct Travel: Decodable { var small: Float?; var home: Float? }
        struct Material: Decodable { var base: String?; var orm: String?; var normal: String?; var emission: String?; var alpha: String? }
        var parts: [String: Part]
        var materials: [String: Material]
        var roles: [String: String]?
        var decals: [String: String]?
    }

    init?(model: PadModel3D, bundle: Bundle = .main) {
        func file(_ name: String, _ ext: String) -> URL? { bundle.url(forResource: name, withExtension: ext, subdirectory: "Models") ?? bundle.url(forResource: name, withExtension: ext) }
        guard let url = file(model.base, "usdc"), let json = file(model.base, "json"),
              let data = try? Data(contentsOf: json), let description = try? JSONDecoder().decode(Description.self, from: data),
              let scene = try? SCNScene(url: url, options: nil),
              let model3 = scene.rootNode.childNode(withName: model.root, recursively: false) else { return nil }
        self.model = model
        let model = model3
        self.description = description
        model.removeFromParentNode()
        for name in description.parts.keys {
            guard let node = model.childNode(withName: name, recursively: false) else { continue }
            parts[name] = node
            rest[name] = node.simdTransform
        }
        if let r = description.roles { roles = r }
        if let d = description.decals { decals = d } else if self.model == .dualSense {
            decals = ["cross": "cross", "circle": "circle", "square": "square", "triangle": "triangle", "dpad_up": "up", "dpad_down": "down", "dpad_left": "left", "dpad_right": "right"]
        }
        guard parts.keys.contains(where: { $0.hasPrefix("static") }), let ls = roles["ls"], parts[ls] != nil else { return nil }
        for stray in ["env_light", "_materials"] { model.childNode(withName: stray, recursively: false)?.removeFromParentNode() }
        // Centre it and make it 16 units across whatever unit the file was written in, then turn it from Z up to Y up (the touchpad ends up away from a camera looking along -Z).
        let (lo, hi) = model.boundingBox
        let width = Float(hi.x - lo.x) * Float(model.scale.x)
        let unit = width > 0 ? 16 / width : 1
        let scaled = SCNNode()
        scaled.addChildNode(model)
        scaled.simdScale = SIMD3<Float>(repeating: unit)
        let centre = SIMD3<Float>(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z + hi.z) / 2) * Float(model.scale.x)
        scaled.simdPosition = -centre * unit
        let turned = SCNNode()
        spin.addChildNode(scaled)
        turned.addChildNode(spin)
        turned.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
        root.addChildNode(turned)
        dress(bundle: bundle)
        addSymbols()
    }

    /// The pad's orientation, as the real one is held (identity = flat and facing the player).
    func setSpin(_ q: simd_quatf) { spin.simdOrientation = q }

    // MARK: Look

    private func image(_ name: String?, bundle: Bundle) -> UIImage? {
        guard let name else { return nil }
        if let cached = images[name] { return cached }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext, subdirectory: "Models") ?? bundle.url(forResource: base, withExtension: ext),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        images[name] = img
        return img
    }

    /// One material of the model, made again for the part that uses it (a lit button must not light another), from the model's own textures.
    private func make(_ name: String, bundle: Bundle) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = .physicallyBased
        guard let spec = description?.materials[name] else { return m }
        m.diffuse.contents = image(spec.base, bundle: bundle)
        if let orm = image(spec.orm, bundle: bundle) {
            m.roughness.contents = orm; m.roughness.textureComponents = .green
            m.metalness.contents = orm; m.metalness.textureComponents = .blue
            m.ambientOcclusion.contents = orm; m.ambientOcclusion.textureComponents = .red
        } else {
            m.roughness.contents = 0.45; m.metalness.contents = 0.0   // a model with no roughness map of its own (the Xbox's)
        }
        m.normal.contents = image(spec.normal, bundle: bundle)
        if let emission = image(spec.emission, bundle: bundle) { m.emission.contents = emission }
        // The model marks a quarter of its button texture as see-through (the faces of the buttons, which are clear plastic on the real pad), and the colours under it are the plastic and the symbols
        // printed on it. Drawn see-through the buttons look like holes, so every material is opaque.
        m.isDoubleSided = false
        return m
    }

    private func dress(bundle: Bundle) {
        guard let description else { return }
        for (name, part) in description.parts {
            guard let node = parts[name] else { continue }
            let geometry = node.childNodes.first?.geometry ?? node.geometry
            guard let geometry else { continue }
            let made = part.materials.map { make($0, bundle: bundle) }
            if !made.isEmpty { geometry.materials = made }
            materials[name] = made
            restEmission[name] = made.map { $0.emission.contents }
        }
    }

    // MARK: Symbols

    private enum Symbol { case cross, circle, square, triangle, up, down, left, right }

    /// The model keeps each button's symbol inside its clear cap, where a solid cap hides it, so the symbols are printed on the caps again: thin decals that sit on the cap's surface and
    /// move and glow with the button.
    private func addSymbols() {
        guard let description else { return }
        let kinds: [String: Symbol] = ["cross": .cross, "circle": .circle, "square": .square, "triangle": .triangle, "up": .up, "down": .down, "left": .left, "right": .right]
        for (name, kind) in decals {
            guard let symbol = kinds[kind], let node = parts[name], let cap = description.parts[name]?.cap, cap.normal.count == 3 else { continue }
            let size = CGFloat(cap.radius) * (symbol == .up || symbol == .down || symbol == .left || symbol == .right ? 0.9 : 1.2)
            let plane = SCNPlane(width: size, height: size)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = Self.symbolImage(symbol)
            m.transparencyMode = .aOne
            m.writesToDepthBuffer = false
            m.isDoubleSided = false
            plane.materials = [m]
            let decal = SCNNode(geometry: plane)
            decal.simdPosition = SIMD3<Float>(cap.x, cap.y, cap.z + 0.07)
            decal.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(SIMD3<Float>(cap.normal[0], cap.normal[1], cap.normal[2])))
            node.addChildNode(decal)
        }
    }

    private static func symbolImage(_ symbol: Symbol) -> UIImage {
        let side: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let ink = UIColor(white: 0.5, alpha: 1)
            ink.setStroke(); ink.setFill()
            c.setLineWidth(15); c.setLineCap(.round); c.setLineJoin(.round)
            let m = side / 2, r: CGFloat = 78
            switch symbol {
            case .cross:
                c.move(to: CGPoint(x: m - r, y: m - r)); c.addLine(to: CGPoint(x: m + r, y: m + r))
                c.move(to: CGPoint(x: m + r, y: m - r)); c.addLine(to: CGPoint(x: m - r, y: m + r)); c.strokePath()
            case .circle:
                c.strokeEllipse(in: CGRect(x: m - r, y: m - r, width: 2 * r, height: 2 * r))
            case .square:
                c.stroke(CGRect(x: m - r * 0.92, y: m - r * 0.92, width: 2 * r * 0.92, height: 2 * r * 0.92))
            case .triangle:
                c.move(to: CGPoint(x: m, y: m - r)); c.addLine(to: CGPoint(x: m + r * 0.95, y: m + r * 0.72)); c.addLine(to: CGPoint(x: m - r * 0.95, y: m + r * 0.72)); c.closePath(); c.strokePath()
            case .up, .down, .left, .right:
                // A filled arrowhead; the picture's top is the pad's +Y, so "up" points up.
                let a = r * 0.85
                let tip: CGPoint, b1: CGPoint, b2: CGPoint
                switch symbol {
                case .up: tip = CGPoint(x: m, y: m - a); b1 = CGPoint(x: m - a, y: m + a * 0.7); b2 = CGPoint(x: m + a, y: m + a * 0.7)
                case .down: tip = CGPoint(x: m, y: m + a); b1 = CGPoint(x: m - a, y: m - a * 0.7); b2 = CGPoint(x: m + a, y: m - a * 0.7)
                case .left: tip = CGPoint(x: m - a, y: m); b1 = CGPoint(x: m + a * 0.7, y: m - a); b2 = CGPoint(x: m + a * 0.7, y: m + a)
                default: tip = CGPoint(x: m + a, y: m); b1 = CGPoint(x: m - a * 0.7, y: m - a); b2 = CGPoint(x: m - a * 0.7, y: m + a)
                }
                c.move(to: tip); c.addLine(to: b1); c.addLine(to: b2); c.closePath(); c.fillPath()
            }
        }
    }

    // MARK: Moving

    /// What a lit part glows with.
    private var glow: UIColor { UIColor(Theme.accent) }

    private func light(_ name: String, _ amount: CGFloat) {
        guard let list = materials[name], let originals = restEmission[name] else { return }
        for (m, original) in zip(list, originals) {
            if amount > 0.01 {
                m.emission.contents = glow
                m.emission.intensity = amount * 0.6          // a glow the plastic still shows through
            } else {
                m.emission.contents = original
                m.emission.intensity = 1
            }
        }
    }

    private func move(_ name: String, _ delta: simd_float4x4) {
        guard let node = parts[name], let base = rest[name] else { return }
        node.simdTransform = base * delta
    }

    private static func rotation(_ angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
    }

    private static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(v.x, v.y, v.z, 1)
        return m
    }

    /// Puts every moving part where the controller's reading says it is.
    func apply(_ pad: PadReading, everPressed: Set<PadButton>) {
        // A thumbstick turns about a point under the plate, not at its cap, so the cap slides toward where the thumb pushes as well as leaning: about 4 mm at the foot of the cap, 6 at its top.
        let tilt: Float = 18 * .pi / 180
        let under: Float = 12
        for (role, x, y, click) in [("ls", pad.lx, pad.ly, PadButton.leftStick), ("rs", pad.rx, pad.ry, PadButton.rightStick)] {
            guard let name = roles[role] else { continue }
            let down: Float = pad.held.contains(click) ? -1.6 : 0
            // Rightward = turn about Y by +, forward (+Y) = turn about X by -.
            let turn = Self.rotation(Float(x) * tilt, axis: [0, 1, 0]) * Self.rotation(-Float(y) * tilt, axis: [1, 0, 0])
            move(name, Self.translation([0, 0, down]) * Self.translation([0, 0, -under]) * turn * Self.translation([0, 0, under]))
            light(name, pad.held.contains(click) ? 0.6 : 0)
        }
        // A d-pad that is one cross (the Xbox's) rocks toward the arm that is held; one of four keys sinks the key.
        if let up = roles["up"], up == roles["down"] {
            let rock: Float = 5 * .pi / 180
            var rx: Float = 0, ry: Float = 0
            if pad.held.contains(.up) { rx -= rock }
            if pad.held.contains(.down) { rx += rock }
            if pad.held.contains(.right) { ry += rock }
            if pad.held.contains(.left) { ry -= rock }
            move(up, Self.rotation(rx, axis: [1, 0, 0]) * Self.rotation(ry, axis: [0, 1, 0]))
            let any = [PadButton.up, .down, .left, .right].contains { pad.held.contains($0) }
            light(up, any ? 0.8 : ([PadButton.up, .down, .left, .right].contains { everPressed.contains($0) } ? 0.14 : 0))
        }
        for (role, button) in [("a", PadButton.a), ("b", .b), ("x", .x), ("y", .y), ("up", .up), ("down", .down), ("left", .left), ("right", .right),
                               ("home", .home), ("view", .view), ("menu", .menu)] {
            guard let name = roles[role] else { continue }
            if (role == "up" || role == "down" || role == "left" || role == "right"), roles["up"] == roles["down"] { continue }
            let on = pad.held.contains(button)
            // How far a button sinks: the small ones (Create, Options, PS) stand only about half a millimetre proud of the shell, so they go in just about flush.
            let travel: Float = (role == "view" || role == "menu") ? 0.45 : (role == "home" ? 0.6 : 1.3)
            move(name, Self.translation([0, 0, on ? -travel : 0]))
            light(name, on ? 1 : (everPressed.contains(button) ? 0.16 : 0))
        }
        for (role, button) in [("lb", PadButton.lb), ("rb", .rb)] {
            guard let name = roles[role] else { continue }
            let on = pad.held.contains(button)
            move(name, Self.rotation(on ? -8 * .pi / 180 : 0, axis: [1, 0, 0]))
            light(name, on ? 0.9 : (everPressed.contains(button) ? 0.14 : 0))
        }
        for (role, value) in [("lt", pad.lt), ("rt", pad.rt)] {
            guard let name = roles[role] else { continue }
            let v = max(0, min(1, value))
            move(name, Self.rotation(-Float(v) * 22 * .pi / 180, axis: [1, 0, 0]))
            light(name, CGFloat(v))
        }
    }
}

/// Turns the 3D pad as the real one is turned, from the controller's motion sensors (GameController's frame is the model's: x right, y away from the player, z out of the face). A pad that gives an
/// attitude is used as it is; a DualSense gives its gyro and gravity, which MotionFusion adds up. Nothing says which way is forward, so the heading is taken out at the start and by "Centre", and the
/// pad's real tilt is kept. Read once a frame (the display's own clock), without going through SwiftUI.
@MainActor final class PadMotion3D {
    private weak var rig: PadRig3D?
    private var link: CADisplayLink?
    private var fusion = MotionFusion()
    private var heading: Float?
    private var shown = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var last: CFTimeInterval = 0
    private(set) var following = false
    /// For the preview harness, which has no controller to turn: the orientation at a time.
    var previewSource: ((CFTimeInterval) -> simd_quatf)?

    init(rig: PadRig3D) { self.rig = rig }

    /// The PlayStation pad (DualSense or DualShock 4) in use, if there is one: those are the pads with motion sensors.
    static func controller() -> GCController? { GCController.controllers().first { $0.extendedGamepad is GCDualSenseGamepad || $0.extendedGamepad is GCDualShockGamepad } }

    /// A pad keeps its motion sensors off until asked, as they cost battery: they are on only while this page follows them.
    private static func sensors(_ on: Bool) {
        for c in GCController.controllers() {
            guard let m = c.motion, m.sensorsRequireManualActivation, m.sensorsActive != on else { continue }
            m.sensorsActive = on
        }
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate(); link = nil
        if following { Self.sensors(false) }
        following = false
        rig?.setSpin(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    func follow(_ on: Bool) {
        guard on != following else { return }
        following = on
        if on { fusion.reset(); heading = nil; last = 0 }
        Self.sensors(on)
    }

    /// Make the way the pad faces now "straight ahead".
    func recenter() { heading = nil }

    @objc private func tick(_ link: CADisplayLink) {
        let flat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard following else {
            // Not following: ease back to flat.
            if simd_angle(shown * flat.inverse) > 0.002 { shown = simd_slerp(shown, flat, 0.3); rig?.setSpin(shown) }
            return
        }
        let now = link.timestamp
        let dt = last == 0 ? 0 : Float(now - last)
        last = now
        var q: simd_quatf?
        if let preview = previewSource {
            q = preview(now)
        } else if let motion = Self.controller()?.motion {
            if motion.hasAttitude {
                let a = motion.attitude
                q = simd_quatf(ix: Float(a.x), iy: Float(a.y), iz: Float(a.z), r: Float(a.w))
            } else {
                let rate: SIMD3<Float>? = motion.hasRotationRate ? SIMD3<Float>(Float(motion.rotationRate.x), Float(motion.rotationRate.y), Float(motion.rotationRate.z)) : nil
                let gravity: SIMD3<Float>? = motion.hasGravityAndUserAcceleration ? SIMD3<Float>(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z)) : nil
                fusion.update(rate: rate, gravity: gravity, dt: dt)
                q = fusion.orientation
            }
        }
        guard let q else { return }
        let h = heading ?? MotionFusion.heading(of: q)
        heading = h
        let target = MotionFusion.levelled(q, heading: h)
        // A little smoothing takes the jitter out without a visible lag.
        shown = simd_slerp(shown, target, 0.5)
        rig?.setSpin(shown)
    }
}

/// The 3D view: the pad on a transparent background, lit like a product shot, that can be turned by dragging and zoomed by pinching. Double-tap puts it back.
struct Pad3DView: UIViewRepresentable {
    let model: PadModel3D
    let pad: PadReading
    let everPressed: Set<PadButton>
    /// Turn the model as the real controller is turned. A double-tap puts the view back, centres the motion and calls `onReset`.
    var followMotion = true
    var onReset: () -> Void = {}
    /// For the preview harness, which has no controller to turn: the orientation at a time. nil in the app.
    nonisolated(unsafe) static var previewMotion: ((CFTimeInterval) -> simd_quatf)?
    /// For the preview harness, which cannot pinch and drag precisely: where the camera stands and what it looks at. nil in the app.
    nonisolated(unsafe) static var previewCamera: (position: SIMD3<Float>, target: SIMD3<Float>)?

    @MainActor final class Coordinator: NSObject {
        var rig: PadRig3D?
        var motion: PadMotion3D?
        var onReset: () -> Void = {}
        var home: simd_float4x4 = matrix_identity_float4x4
        weak var view: SCNView?
        @objc func reset() {
            motion?.recenter()
            onReset()
            guard let view, let camera = view.pointOfView else { return }
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.35
            camera.simdTransform = home
            SCNTransaction.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false       // draws when the pad or the camera changes, not sixty times a second for nothing
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        view.scene = scene

        guard let rig = PadRig3D(model: model) else { return view }
        context.coordinator.rig = rig
        if model.hasMotion {
            let motion = PadMotion3D(rig: rig)
            motion.previewSource = Self.previewMotion
            motion.start()
            context.coordinator.motion = motion
        }
        scene.rootNode.addChildNode(rig.root)
        scene.lightingEnvironment.contents = Self.studio()
        scene.lightingEnvironment.intensity = 0.9

        let camera = SCNNode()
        camera.camera = SCNCamera()
        // The field of view is across the picture, so the pad fits whatever shape the card is (tall on a phone, wide on an iPad).
        camera.camera?.projectionDirection = .horizontal
        camera.camera?.fieldOfView = 33
        camera.camera?.zNear = 1
        camera.camera?.zFar = 200
        // Above and behind the pad, the way the player sees it.
        camera.simdPosition = SIMD3<Float>(0, 22, 19)
        camera.simdLook(at: SIMD3<Float>(0, -1.0, -0.5))
        if let preview = Self.previewCamera { camera.simdPosition = preview.position; camera.simdLook(at: preview.target) }
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        context.coordinator.home = camera.simdTransform

        func light(_ position: SIMD3<Float>, intensity: CGFloat) {
            let l = SCNNode()
            l.light = SCNLight()
            l.light?.type = .directional
            l.light?.intensity = intensity
            l.light?.temperature = 6500
            l.simdPosition = position
            l.simdLook(at: .zero)
            scene.rootNode.addChildNode(l)
        }
        light([10, 22, 12], intensity: 700)
        light([-16, 6, 4], intensity: 250)
        light([0, 5, -18], intensity: 400)

        view.allowsCameraControl = true
        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.target = SCNVector3(0, 0, 0)
        controller.maximumVerticalAngle = 85
        controller.minimumVerticalAngle = -85
        context.coordinator.view = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.rig?.apply(pad, everPressed: everPressed)
        context.coordinator.onReset = onReset
        if let motion = context.coordinator.motion {
            motion.follow(followMotion)
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) { coordinator.motion?.stop() }

    /// A small studio for the reflections: a dim room with two soft boxes, so the glossy plastic has something to shine.
    private static func studio() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor(white: 0.12, alpha: 1).cgColor, UIColor(white: 0.34, alpha: 1).cgColor, UIColor(white: 0.14, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
                c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(white: 1, alpha: 0.95).setFill()
            c.fill(CGRect(x: 60, y: 40, width: 130, height: 60))
            UIColor(white: 0.9, alpha: 0.8).setFill()
            c.fill(CGRect(x: 330, y: 70, width: 110, height: 45))
            UIColor(white: 0.7, alpha: 0.7).setFill()
            c.fill(CGRect(x: 200, y: 190, width: 120, height: 30))
        }
    }
}
