// A small app for the iOS Simulator that hosts the real on-screen controls and the real editor over a stand-in game screen, with the runtime's C calls stubbed.
//   app/Tests/ControlsEditor/build.sh              build + install + launch on the booted simulator
// Launch arguments: --edit (start in editing), --select <n> (select the n-th control), --layout fp|keys|empty
import UIKit
import SwiftUI

// The runtime's C functions and the log, as stand-ins.
var sentKeys: [String] = []
func winios_post_key(_ vk: Int32, _ down: Int32) { sentKeys.append("\(vk):\(down)") }
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) { sentKeys.append("ptr:\(flags)") }
// The app's game record, reduced to what BindSets.swift extends.
struct Game { var bindSets: [BindSet]?; var activeBindSetID: UUID? }
protocol TakesHUDTouches: UIView {}
final class LogStore { static let shared = LogStore(); func log(_ s: String, level: Int = 0) {} }

final class HarnessController: UIViewController {
    let controls = CustomControlsView()
    lazy var editor = ControlsEditorView(controls: controls)
    let pencil = UIButton(type: .system)
    let status = UILabel()
    var saves = 0

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        let game = UIView(frame: view.bounds); game.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let grad = CAGradientLayer(); grad.colors = [UIColor(red: 0.18, green: 0.32, blue: 0.22, alpha: 1).cgColor, UIColor(red: 0.05, green: 0.08, blue: 0.1, alpha: 1).cgColor]
        grad.frame = view.bounds; game.layer.addSublayer(grad); view.addSubview(game)
        let t = UILabel(); t.text = "the game"; t.textColor = UIColor(white: 1, alpha: 0.25); t.font = .systemFont(ofSize: 60, weight: .heavy); t.sizeToFit(); t.center = view.center; game.addSubview(t)

        let args = CommandLine.arguments
        var start = ShippedLayouts.universal.layout
        if let i = args.firstIndex(of: "--layout"), i + 1 < args.count { start = args[i + 1] == "fp" ? ShippedLayouts.action.layout : args[i + 1] == "empty" ? TouchLayout() : ShippedLayouts.universal.layout }
        controls.frame = view.bounds; controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controls); controls.apply(start)
        controls.onChange = { [weak self] l in self?.saves += 1; self?.updateStatus(l) }
        editor.frame = view.bounds; editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(editor); editor.onDone = { [weak self] in self?.setEditing(false) }

        pencil.setImage(UIImage(systemName: "pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        pencil.tintColor = .white; pencil.backgroundColor = UIColor(white: 0, alpha: 0.55); pencil.layer.cornerRadius = 8
        pencil.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        pencil.addAction(UIAction { [weak self] _ in self?.setEditing(true) }, for: .touchUpInside)
        pencil.frame = CGRect(x: 90, y: 14, width: 44, height: 36); view.addSubview(pencil)
        status.textColor = .white; status.font = .monospacedSystemFont(ofSize: 10, weight: .regular); status.numberOfLines = 0
        status.frame = CGRect(x: 12, y: 60, width: 400, height: 40); view.addSubview(status); updateStatus(controls.layout ?? TouchLayout())
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in guard let self else { return }; self.updateStatus(self.controls.layout ?? TouchLayout()) }
        if args.contains("--edit") { DispatchQueue.main.async { self.setEditing(true); if let i = args.firstIndex(of: "--select"), i + 1 < args.count, let n = Int(args[i + 1]) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if let id = self.controls.layout?.controls[safe: n]?.id { self.controls.select(id) } } }
            // --select-many 0,1,2: select those controls; --select-mode: switch Select mode on
            if let i = args.firstIndex(of: "--select-many"), i + 1 < args.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.controls.selectIndices(args[i + 1].split(separator: ",").compactMap { Int($0) }) } }
            if args.contains("--select-mode") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.controls.multiSelect = true } } } }
    }

    func setEditing(_ on: Bool) { editor.setActive(on); pencil.isHidden = on }
    func updateStatus(_ l: TouchLayout) { status.text = "controls \(l.controls.count) · look \(l.look) · saves \(saves) · keys sent \(sentKeys.count)" }
}

extension CustomControlsView {
    func selectIndices(_ indices: [Int]) { selectIDs(indices.compactMap { layout?.controls[safe: $0]?.id }) }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

struct HarnessRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HarnessController { HarnessController() }
    func updateUIViewController(_ controller: HarnessController, context: Context) {}
}

@main struct HarnessApp: App {
    var body: some Scene { WindowGroup { HarnessRepresentable().ignoresSafeArea().statusBarHidden() } }
}
