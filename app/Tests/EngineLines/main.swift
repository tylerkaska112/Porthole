import Foundation
// Run: app/Tests/EngineLines/run.sh
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

check(EngineLines.rule(forExe: "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Blender\\blender.exe", steamAppID: nil) == EngineLines.blender, "blender.exe in a Windows path is Blender")
check(EngineLines.rule(forExe: "BLENDER.EXE", steamAppID: nil) != nil && EngineLines.rule(forExe: "/x/blender-launcher.exe", steamAppID: nil) != nil, "case and the launcher do not matter")
check(EngineLines.rule(forExe: "", steamAppID: 365960) != nil, "Steam's Blender is found by its id")
check(EngineLines.rule(forExe: "C:\\Games\\blenderfarm.exe", steamAppID: 440) == nil && EngineLines.rule(forExe: "C:\\mod\\myblender.exe", steamAppID: nil) == nil, "other programs, even with blender in the name, get no rule")

let all = EngineLines.blender.lines
check(EngineLines.missing(all, in: nil) == all && EngineLines.missing(all, in: "") == all, "an empty text misses all three")
check(EngineLines.missing(all, in: all.joined(separator: "\n")).isEmpty, "the three lines present: nothing missing")
check(EngineLines.missing(all, in: "env.MESA_GL_VERSION_OVERRIDE=4.6\n env.mesa_glsl_version_override = 460 \nenv.MESA_EXTENSION_OVERRIDE = +X").isEmpty, "the person's own values count, with any spacing or case")
let some = EngineLines.missing(all, in: "env.FOO = 1\nenv.MESA_GL_VERSION_OVERRIDE = 4.3")
check(some.count == 2 && !some.contains { $0.contains("MESA_GL_VERSION") }, "only the lines not mentioned are missing: \(some)")
check(EngineLines.adding(all, to: nil) == all.joined(separator: "\n"), "added to nothing: just the lines")
let merged = EngineLines.adding(some, to: "env.FOO = 1\nenv.MESA_GL_VERSION_OVERRIDE = 4.3\n\n")
check(merged == "env.FOO = 1\nenv.MESA_GL_VERSION_OVERRIDE = 4.3\n" + some.joined(separator: "\n"), "added after what was there, which is kept: \(merged)")
check(EngineLines.missing(all, in: merged).isEmpty, "after adding, nothing is missing")
exit(failures == 0 ? 0 : 1)
