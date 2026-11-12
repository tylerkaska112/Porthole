import Foundation
// Run: app/Tests/SideBySide/run.sh
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }
let fm = FileManager.default
func tempDir() -> URL { let u = fm.temporaryDirectory.appendingPathComponent("sxs-\(UUID().uuidString)"); try! fm.createDirectory(at: u, withIntermediateDirectories: true); return u }
func write(_ s: String, _ u: URL) { try! Data(s.utf8).write(to: u) }
func pe(machine: UInt16) -> Data {
    var d = Data(count: 128); d[60] = 0x40; d[0x40] = 0x50; d[0x41] = 0x45; d[0x44] = UInt8(machine & 0xff); d[0x45] = UInt8(machine >> 8); return d
}

let manifest = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
<assemblyIdentity type="win32" name="blender.shared" version="1.0.0.0" processorArchitecture="amd64"/>
<file name="tbb12.dll"/><file name='gmp-10.dll' hashalg="SHA1"/>
<file name="../evil.dll"/><file name="sub\\\\bad.dll"/><file name="Missing.dll"/>
</assembly>
"""
check(SideBySide.manifestFiles(manifest) == ["tbb12.dll", "gmp-10.dll", "Missing.dll"], "manifest names are read, paths in names are dropped: \(SideBySide.manifestFiles(manifest))")
check(SideBySide.manifestFiles("<assembly/>").isEmpty, "a manifest with no files lists none")

// ---- a Blender-like folder
let app = tempDir(); let shared = app.appendingPathComponent("blender.shared"); try! fm.createDirectory(at: shared, withIntermediateDirectories: true)
write(manifest, shared.appendingPathComponent("blender.shared.manifest"))
write("tbb", shared.appendingPathComponent("tbb12.dll")); write("gmp", shared.appendingPathComponent("GMP-10.dll")); write("x", shared.appendingPathComponent("unlisted.dll"))
write("exe", app.appendingPathComponent("blender.exe"))
let first = SideBySide.prepare(folder: app, extras: nil)
check(first.count == 1 && first[0].hasPrefix("blender.shared: 2 libraries"), "the two listed libraries are put next to the program: \(first)")
check(fm.fileExists(atPath: app.appendingPathComponent("tbb12.dll").path) && fm.fileExists(atPath: app.appendingPathComponent("GMP-10.dll").path), "both are there (case of the real file kept)")
check(!fm.fileExists(atPath: app.appendingPathComponent("unlisted.dll").path), "a library the manifest does not list is not touched")
check(fm.fileExists(atPath: shared.appendingPathComponent("tbb12.dll").path), "the shared folder keeps its own files")
let a = try! fm.attributesOfItem(atPath: app.appendingPathComponent("tbb12.dll").path), b = try! fm.attributesOfItem(atPath: shared.appendingPathComponent("tbb12.dll").path)
check((a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber), "it is a hard link: no second copy on the disk")
check(SideBySide.prepare(folder: app, extras: nil).isEmpty, "running again changes nothing")

// ---- an update replaces the shared file (a new file, as Steam writes it): the link is refreshed
try! fm.removeItem(at: shared.appendingPathComponent("tbb12.dll")); write("tbb-new-version", shared.appendingPathComponent("tbb12.dll"))
let second = SideBySide.prepare(folder: app, extras: nil)
check(second.count == 1 && second[0].contains("1 refreshed"), "a changed library is refreshed: \(second)")
check((try? String(contentsOf: app.appendingPathComponent("tbb12.dll"), encoding: .utf8)) == "tbb-new-version", "the program's copy has the new content")

// ---- a file the person put there is never replaced
let own = tempDir(); let ownShared = own.appendingPathComponent("p.shared"); try! fm.createDirectory(at: ownShared, withIntermediateDirectories: true)
write("<assembly><file name=\"a.dll\"/></assembly>", ownShared.appendingPathComponent("p.shared.manifest")); write("from-shared", ownShared.appendingPathComponent("a.dll")); write("mine", own.appendingPathComponent("a.dll"))
let kept = SideBySide.prepare(folder: own, extras: nil)
check((try? String(contentsOf: own.appendingPathComponent("a.dll"), encoding: .utf8)) == "mine" && kept.first?.contains("1 left alone") == true, "an existing file that was not made here stays: \(kept)")

// ---- a folder with no manifest is left alone
let plain = tempDir(); try! fm.createDirectory(at: plain.appendingPathComponent("data"), withIntermediateDirectories: true); write("x", plain.appendingPathComponent("data/x.dll"))
check(SideBySide.prepare(folder: plain, extras: nil).isEmpty && !fm.fileExists(atPath: plain.appendingPathComponent(SideBySide.ledgerName).path), "a folder with no manifest gets nothing, not even a list")

// ---- avicap32.dll for avdevice
let extras = tempDir()
for v in ["arm64ec", "aarch64"] { try! fm.createDirectory(at: extras.appendingPathComponent(v), withIntermediateDirectories: true); write("avicap-\(v)", extras.appendingPathComponent(v).appendingPathComponent("avicap32.dll")) }
check(SideBySide.machine(of: app.appendingPathComponent("blender.exe")) == nil, "a file that is not a PE has no machine")
let x64 = tempDir(); try! pe(machine: 0x8664).write(to: x64.appendingPathComponent("avdevice-62.dll"))
let l1 = SideBySide.prepare(folder: x64, extras: extras)
check(l1.count == 1 && (try? String(contentsOf: x64.appendingPathComponent("avicap32.dll"), encoding: .utf8)) == "avicap-arm64ec", "an x64 program gets the x64 build: \(l1)")
let arm = tempDir(); try! pe(machine: 0xAA64).write(to: arm.appendingPathComponent("AVDEVICE-62.DLL"))
let l2 = SideBySide.prepare(folder: arm, extras: extras)
check(l2.count == 1 && (try? String(contentsOf: arm.appendingPathComponent("avicap32.dll"), encoding: .utf8)) == "avicap-aarch64", "a native Arm program gets the Arm build: \(l2)")
check(SideBySide.prepare(folder: arm, extras: extras).isEmpty, "and only once")
let withOwn = tempDir(); try! pe(machine: 0x8664).write(to: withOwn.appendingPathComponent("avdevice-62.dll")); write("theirs", withOwn.appendingPathComponent("AviCap32.dll"))
check(SideBySide.prepare(folder: withOwn, extras: extras).isEmpty && (try? String(contentsOf: withOwn.appendingPathComponent("AviCap32.dll"), encoding: .utf8)) == "theirs", "an avicap32.dll that is already there is left alone")
let noDevice = tempDir(); write("x", noDevice.appendingPathComponent("game.exe"))
check(SideBySide.prepare(folder: noDevice, extras: extras).isEmpty && !fm.fileExists(atPath: noDevice.appendingPathComponent("avicap32.dll").path), "a program with no avdevice library gets no avicap32.dll")
exit(failures == 0 ? 0 : 1)
