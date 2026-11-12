import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok:   \(name)" : "FAIL: \(name)"); if !ok { failed += 1 } }

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
let root = tmp.appendingPathComponent("drive_c")
func make(_ rel: String) { let u = root.appendingPathComponent(rel); try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8)) }
func unix(_ p: String) -> URL? {
    guard p.count > 3, p.lowercased().hasPrefix("c:\\") else { return nil }
    return p.dropFirst(3).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init).reduce(root) { $0.appendingPathComponent($1) }
}
func windows(_ rel: String) -> String { "C:\\" + rel.split(separator: "/").joined(separator: "\\") }
func find(_ exe: String) -> String? { ProgramRepair.find(missing: exe, root: root, unix: unix, windows: windows) }

let common = "Program Files (x86)/Steam/steamapps/common"
// The damaged paths from real reports: eight characters of the folder's name in the middle.
make("\(common)/Ranch Simulator/Ranch_Simulator.exe")
make("\(common)/BurnoutPR/BurnoutPR_trial.exe")
check("Ranch Simulator damaged path is repaired",
      find("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Ranch Simulator\\mulator\\Ranch_Simulator.exe") == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Ranch Simulator\\Ranch_Simulator.exe")
check("Burnout damaged path is repaired",
      find("C:\\Program Files (x86)\\Steam\\steamapps\\common\\BurnoutPR\\rnoutPR\\BurnoutPR_trial.exe") == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\BurnoutPR\\BurnoutPR_trial.exe")
check("the name is matched without regard to case",
      find("C:\\Program Files (x86)\\Steam\\steamapps\\common\\BurnoutPR\\x\\BURNOUTPR_TRIAL.EXE")?.hasSuffix("BurnoutPR_trial.exe") == true)

// A program moved inside the game's own folder.
make("Games/Foo/bin64/foo.exe")
check("a program moved deeper in its own folder is found", find("C:\\Games\\Foo\\foo.exe") == "C:\\Games\\Foo\\bin64\\foo.exe")

// A game whose whole folder is gone: never searched for in the folder that holds other games.
make("\(common)/Other Game/Ranch_Simulator2.exe")
make("\(common)/Another/gone.exe")
check("a deleted game folder is not searched for in 'common'", find("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Deleted\\gone.exe") == nil)
check("a file that does not exist anywhere gives nil", find("C:\\Games\\Foo\\nothing.exe") == nil)

// Two files of that name at the same depth: no answer.
make("Games/Bar/a/tool.exe"); make("Games/Bar/b/tool.exe")
check("two equally likely files give nil", find("C:\\Games\\Bar\\tool.exe") == nil)
// A nearer one wins over a deeper one.
make("Games/Baz/tool.exe.bak"); make("Games/Baz/x/tool.exe"); make("Games/Baz/x/y/tool.exe")
check("the nearer file wins", find("C:\\Games\\Baz\\missing\\tool.exe") == "C:\\Games\\Baz\\x\\tool.exe")
// Not an exe, not a C: path, a top-level folder.
check("a path that is not a program gives nil", find("C:\\Games\\Foo\\readme.txt") == nil)
check("a path outside C: gives nil", find("D:\\Games\\Foo\\foo.exe") == nil)
make("Tools/solo.exe")
check("a one-level folder is too wide to search", find("C:\\Tools\\sub\\solo.exe") == nil)

try? FileManager.default.removeItem(at: tmp)
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
