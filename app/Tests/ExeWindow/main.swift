import Foundation
// Run: app/Tests/ExeWindow/run.sh
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

/// A minimal PE header: DOS stub pointing at a PE header at 0x80, with the fields ExecutableWindow reads.
func pe(is64: Bool, base: UInt64, relocSize: UInt32, stripped: Bool = false) -> Data {
    var d = Data(count: 1024)
    func put16(_ o: Int, _ v: UInt16) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8(v >> 8) }
    func put32(_ o: Int, _ v: UInt32) { put16(o, UInt16(v & 0xFFFF)); put16(o + 2, UInt16(v >> 16)) }
    func put64(_ o: Int, _ v: UInt64) { put32(o, UInt32(v & 0xFFFF_FFFF)); put32(o + 4, UInt32(v >> 32)) }
    put16(0, 0x5A4D); put32(0x3C, 0x80); put32(0x80, 0x0000_4550)
    put16(0x80 + 20, is64 ? 240 : 224); put16(0x80 + 22, stripped ? 0x0001 | 0x0022 : 0x0022)
    let opt = 0x80 + 24
    put16(opt, is64 ? 0x20B : 0x10B)
    if is64 { put64(opt + 24, base); put32(opt + 112 + 5 * 8 + 4, relocSize) } else { put32(opt + 28, UInt32(base)); put32(opt + 96 + 5 * 8 + 4, relocSize) }
    return d
}

let movable = ExecutableWindow.parse(header: pe(is64: true, base: 0x1_4000_0000, relocSize: 0x1234))!
check(movable.is64Bit && movable.imageBase == 0x1_4000_0000 && !movable.relocationsStripped && !ExecutableWindow.needsWindow(movable), "a 64-bit program at 0x140000000 WITH relocations can be moved")
let fixed = ExecutableWindow.parse(header: pe(is64: true, base: 0x1_4000_0000, relocSize: 0))!
check(fixed.relocationsStripped && ExecutableWindow.needsWindow(fixed), "no relocation table at 0x140000000 needs the window (the Red Dead case)")
let flagged = ExecutableWindow.parse(header: pe(is64: true, base: 0x1_4000_0000, relocSize: 0x400, stripped: true))!
check(ExecutableWindow.needsWindow(flagged), "the 'relocations stripped' file flag alone is enough")
let elsewhere = ExecutableWindow.parse(header: pe(is64: true, base: 0x1_8000_0000, relocSize: 0))!
check(!ExecutableWindow.needsWindow(elsewhere), "a program that loads outside the reserved stretch does not need it")
let small = ExecutableWindow.parse(header: pe(is64: false, base: 0x40_0000, relocSize: 0))!
check(!small.is64Bit && small.imageBase == 0x40_0000 && !ExecutableWindow.needsWindow(small), "a 32-bit program at 0x400000 does not need it")
check(ExecutableWindow.parse(header: Data("not a program".utf8)) == nil && ExecutableWindow.parse(header: Data()) == nil, "text and empty data are not programs")
var broken = pe(is64: true, base: 0x1_4000_0000, relocSize: 1); broken[0x80] = 0
check(ExecutableWindow.parse(header: broken) == nil, "a bad PE signature is refused")

// A game folder.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("exewin-\(UUID().uuidString)")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func write(_ name: String, _ data: Data) -> URL { let u = root.appendingPathComponent(name); try! data.write(to: u); return u }
let main = write("game.exe", pe(is64: true, base: 0x1_4000_0000, relocSize: 0x500))
_ = write("crashreporter.exe", pe(is64: false, base: 0x40_0000, relocSize: 0x500))
_ = write("data.exe", Data("just data".utf8))
let fine = ExecutableWindow.releaseReason(forProgram: main)
check(fine.release && fine.text.hasPrefix("2 programs"), "a folder of movable programs gives the window back: \(fine.text)")
_ = write("launcher.exe", pe(is64: true, base: 0x1_4000_0000, relocSize: 0))
let blocked = ExecutableWindow.releaseReason(forProgram: main)
check(!blocked.release && blocked.text.contains("launcher.exe"), "one program in the folder that cannot be moved keeps the window: \(blocked.text)")
let fixedMain = write("fixed.exe", pe(is64: true, base: 0x1_4000_0000, relocSize: 0))
check(!ExecutableWindow.releaseReason(forProgram: fixedMain).release, "the main program itself that cannot be moved keeps the window")
check(!ExecutableWindow.releaseReason(forProgram: root.appendingPathComponent("missing.exe")).release, "a main program that cannot be read keeps the window")
let garbage = write("garbage.exe", Data("MZ??".utf8))
check(!ExecutableWindow.releaseReason(forProgram: garbage).release, "a main program that is not a PE keeps the window")
// An Unreal game: a small launcher in the main folder, the game itself in <Game>/Binaries/Win64.
let ue = root.appendingPathComponent("ue", isDirectory: true)
let ueBin = ue.appendingPathComponent("Game/Binaries/Win64", isDirectory: true)
try! fm.createDirectory(at: ueBin, withIntermediateDirectories: true)
let ueLauncher = ue.appendingPathComponent("Game.exe"); try! pe(is64: true, base: 0x1_4000_0000, relocSize: 0x500).write(to: ueLauncher)
let ueShipping = ueBin.appendingPathComponent("Game-Win64-Shipping.exe"); try! pe(is64: true, base: 0x1_4000_0000, relocSize: 0x500, stripped: true).write(to: ueShipping)
let ueVerdict = ExecutableWindow.releaseReason(forProgram: ueLauncher)
check(!ueVerdict.release && ueVerdict.text.contains("Game/Binaries/Win64/Game-Win64-Shipping.exe"), "a program below the main folder that cannot be moved keeps the window: \(ueVerdict.text)")
try! pe(is64: true, base: 0x1_4000_0000, relocSize: 0x500).write(to: ueShipping)
let ueMovable = ExecutableWindow.releaseReason(forProgram: ueLauncher)
check(ueMovable.release && ueMovable.text.hasPrefix("2 programs"), "movable programs below the main folder are counted and give the window back: \(ueMovable.text)")
let redist = ue.appendingPathComponent("_CommonRedist/vc", isDirectory: true)
try! fm.createDirectory(at: redist, withIntermediateDirectories: true)
try! pe(is64: true, base: 0x1_4000_0000, relocSize: 0).write(to: redist.appendingPathComponent("installer.exe"))
check(ExecutableWindow.releaseReason(forProgram: ueLauncher).release, "programs in redistributable folders are not read")
let deep = ue.appendingPathComponent("a/b/c/d/e", isDirectory: true)
try! fm.createDirectory(at: deep, withIntermediateDirectories: true)
try! pe(is64: true, base: 0x1_4000_0000, relocSize: 0).write(to: deep.appendingPathComponent("toodeep.exe"))
check(ExecutableWindow.releaseReason(forProgram: ueLauncher).release, "programs more than four levels down are not read")
try! pe(is64: true, base: 0x1_4000_0000, relocSize: 0).write(to: ue.appendingPathComponent("a/b/c/d/near.exe"))
check(!ExecutableWindow.releaseReason(forProgram: ueLauncher).release, "a program four levels down is read")
UserDefaults.standard.set(false, forKey: ExecutableWindow.defaultsKey)
check(!ExecutableWindow.releaseReason(forProgram: write("ok.exe", pe(is64: true, base: 0x1_4000_0000, relocSize: 9))).release, "the Settings switch off keeps the window")
UserDefaults.standard.removeObject(forKey: ExecutableWindow.defaultsKey)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
