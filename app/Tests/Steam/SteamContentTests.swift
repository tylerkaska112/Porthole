// SPDX-License-Identifier: GPL-3.0-or-later
// Mac-side tests for SteamContent.swift, SteamInstaller.swift and against a stand-in for Steam's
// content servers (tests/library/SteamContentFixture.swift). STEAM_LIVE=1 also installs Steam's free sample app from the real
// servers, anonymously.
import Foundation
import CryptoKit
import Compression

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("ok:   \(message)") } else { print("FAIL: \(message)"); failures += 1 }
}
func spin(_ seconds: Double = 15, until condition: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("steamcontent-\(UUID().uuidString)")
let fm = FileManager.default
SteamLog.sink = nil
struct LibraryPaths {
    let documents: URL
    var driveC: URL { documents.appendingPathComponent("drive_c") }
    var steamApps: URL { driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps") }
}
func freshPaths(_ name: String) -> LibraryPaths {
    let documents = root.appendingPathComponent(name).appendingPathComponent("Documents")
    try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
    return LibraryPaths(documents: documents)
}
let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 9 &+ 4) })

// MARK: - App information

let info480 = SteamAppInfoParser.parse(ContentFixture.appInfoText(appid: 480, name: "Sample \"Game\"", installDir: "Sample Game", depots: [
    (481, 111, 5000, ""),
    (482, 222, 100, "\t\t\t\"config\"\n\t\t\t{\n\t\t\t\t\"oslist\"\t\"linux\"\n\t\t\t}\n"),
    (483, 333, 100, "\t\t\t\"config\"\n\t\t\t{\n\t\t\t\t\"oslist\"\t\"windows,macos\"\n\t\t\t\t\"osarch\"\t\"64\"\n\t\t\t}\n"),
    (484, 444, 100, "\t\t\t\"config\"\n\t\t\t{\n\t\t\t\t\"oslist\"\t\"windows\"\n\t\t\t\t\"osarch\"\t\"32\"\n\t\t\t}\n"),
    (485, 555, 100, "\t\t\t\"dlcappid\"\t\"9999\"\n"),
    (486, 666, 100, "\t\t\t\"config\"\n\t\t\t{\n\t\t\t\t\"language\"\t\"german\"\n\t\t\t}\n"),
    (487, 777, 100, "\t\t\t\"config\"\n\t\t\t{\n\t\t\t\t\"language\"\t\"english\"\n\t\t\t}\n"),
]), appid: 480)
check(info480?.name == "Sample \"Game\"" && info480?.installDirectory == "Sample Game" && info480?.buildID == "777" && info480?.depots.count == 7, "app info: name, install folder, build and depots are read from Steam's text format")
check(info480?.depots.first?.manifest == 111 && info480?.depots.first?.size == 5000, "app info: a depot's public manifest and size")
check(info480.map { SteamDepotPlanner.windowsDepots(app: $0).map { $0.id } } == [481, 483, 487], "depots: Windows, English, 64-bit when there is a choice; no Linux, no DLC, no other language, no 32-bit")
var only32 = info480!; only32.depots = only32.depots.filter { $0.id == 484 }
check(SteamDepotPlanner.windowsDepots(app: only32).map { $0.id } == [484], "depots: a 32-bit depot is used when it is all there is")
var shared = SteamAppInfo(appid: 1, name: "Shared", installDirectory: nil, buildID: nil, depots: [SteamDepot(id: 5, fromApp: 70)])
check(SteamDepotPlanner.windowsDepots(app: shared).map { $0.id } == [5], "depots: one shared from another app is kept (its manifest is looked up there)")
shared.depots = [SteamDepot(id: 6)]
check(SteamDepotPlanner.windowsDepots(app: shared).isEmpty, "depots: one with no manifest and no source is dropped")
check(SteamDepotPlanner.safeInstallDirectory(SteamAppInfo(appid: 2, name: "x", installDirectory: "../../evil/../name:", buildID: nil, depots: [])) == "_____evil___name_" || !SteamDepotPlanner.safeInstallDirectory(SteamAppInfo(appid: 2, name: "x", installDirectory: "../../evil/../name:", buildID: nil, depots: [])).contains("/"), "install folder: separators and .. cannot escape")
check(SteamDepotPlanner.safeInstallDirectory(SteamAppInfo(appid: 3, name: "  ", installDirectory: "..", buildID: nil, depots: [])) == "App3", "install folder: nothing usable falls back to the app number")
check(SteamAppInfoParser.parse(Data("not keyvalues".utf8), appid: 1) == nil, "app info: junk is refused")

// MARK: - Manifests

let sampleFiles: [ContentFixture.File] = [
    .init(path: "Game.exe", data: ContentFixture.bytes(size: 2500, seed: 1)),
    .init(path: "data\\levels\\one.dat", data: ContentFixture.bytes(size: 3100, seed: 2)),
    .init(path: "data", data: Data(), flags: 64),
    .init(path: "empty.txt", data: Data()),
    .init(path: "_CommonRedist\\vc\\vcredist.exe", data: ContentFixture.bytes(size: 4000, seed: 3)),
    .init(path: "readme.txt", data: Data("hello".utf8)),
]
let depotA = ContentFixture.makeDepot(id: 481, manifestID: 111, key: key, files: sampleFiles)
do {
    let manifest = try SteamManifest.parse(zipped: depotA.manifestZip, depotKey: key)
    check(manifest.depotID == 481 && manifest.manifestID == 111 && manifest.files.count == 6, "manifest: depot, manifest id and file count")
    check(manifest.files[1].path == "data/levels/one.dat" && manifest.files[1].size == 3100 && manifest.files[1].chunks.count == 4, "manifest: encrypted, line-wrapped filenames are decoded, and backslashes become slashes")
    check(manifest.files[2].isDirectory && manifest.files[3].chunks.isEmpty, "manifest: directories and empty files")
    check(manifest.files[0].chunks[1].offset == 1000 && manifest.files[0].chunks[1].originalSize == 1000 && manifest.files[0].chunks[2].originalSize == 500, "manifest: chunk offsets and sizes")
    check(manifest.files[0].chunks[0].sha == SteamCipher.sha1(sampleFiles[0].data.prefix(1000)), "manifest: chunk hashes are the SHA-1 of the plain chunk")
    let plain = ContentFixture.makeDepot(id: 9, manifestID: 5, key: key, files: [.init(path: "a/b.txt", data: Data("x".utf8))], encryptNames: false)
    check((try? SteamManifest.parse(zipped: plain.manifestZip, depotKey: key))?.files.first?.path == "a/b.txt", "manifest: unencrypted filenames work too")
} catch { check(false, "manifest parses (\(error))") }
check((try? SteamManifest.parse(zipped: depotA.manifestZip, depotKey: Data(repeating: 1, count: 32))) == nil, "manifest: the wrong depot key is refused")
check((try? SteamManifest.parse(zipped: Data(repeating: 7, count: 50), depotKey: key)) == nil, "manifest: junk is refused")
for evil in ["../escape.txt", "a/../../escape.txt", "/etc/passwd", "a/./b.txt"] {
    let bad = ContentFixture.makeDepot(id: 9, manifestID: 5, key: key, files: [.init(path: evil, data: Data("x".utf8))])
    check((try? SteamManifest.parse(zipped: bad.manifestZip, depotKey: key)) == nil, "manifest: the filename \(evil) is refused")
}

// MARK: - Content servers

let cdn = SteamCDN.parse(["servers": [
    ["host": "cache1.steamcontent.com", "vhost": "cache1.steamcontent.com", "https_support": "mandatory", "type": "SteamCache"],
    ["host": "partner.akamaihd.net", "https_support": "optional", "type": "CDN"],
    ["host": "old.steamcontent.com", "https_support": "unavailable"],
    ["host": "cache2.steamcontent.com", "vhost": "cache2.steamcontent.com", "https_support": "optional"]]])
check(cdn.map { $0.host } == ["cache1.steamcontent.com", "cache2.steamcontent.com"], "content servers: Steam's own caches only, https, nothing marked unavailable")
check(SteamCDN.parse(["servers": [["host": "x.example.net", "https_support": "optional"]]]).map { $0.host } == ["x.example.net"], "content servers: another host is used when there is no Steam cache")
check(SteamCDN.manifestURL(cdn[0], depot: 481, manifest: 111, code: 99)?.absoluteString == "https://cache1.steamcontent.com/depot/481/manifest/111/5/99", "content servers: manifest address")
check(SteamCDN.chunkURL(cdn[0], depot: 481, sha: Data([0xAB, 0x01]))?.absoluteString == "https://cache1.steamcontent.com/depot/481/chunk/ab01", "content servers: chunk address (lowercase hex)")

// MARK: - The installer

func makeStore(appid: Int, name: String, depots: [ContentFixture.Depot], installDir: String = "Sample Game", extra: [Int: String] = [:]) -> FakeContent {
    let fake = FakeContent()
    fake.apps[appid] = SteamAppInfoParser.parse(ContentFixture.appInfoText(appid: appid, name: name, installDir: installDir,
        depots: depots.map { ($0.id, $0.manifestID, $0.totalSize, extra[$0.id] ?? "") }), appid: appid)!
    for depot in depots { fake.depots[depot.id] = depot }
    return fake
}
func run(_ installer: SteamInstaller, timeout: Double = 30) {
    installer.start()
    spin(timeout) { installer.state.isFinal }
}
func read(_ paths: LibraryPaths, _ relative: String) -> Data? {
    try? Data(contentsOf: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Sample Game/" + relative))
}

do {   // a complete install
    let paths = freshPaths("full")
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    let installer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    var states: [SteamInstaller.State] = []
    installer.onState = { states.append($0) }
    run(installer)
    check(installer.state == .finished, "install: finishes (\(installer.state))")
    check(read(paths, "Game.exe") == sampleFiles[0].data && read(paths, "data/levels/one.dat") == sampleFiles[1].data && read(paths, "readme.txt") == Data("hello".utf8), "install: every file has exactly the right bytes")
    check(read(paths, "empty.txt")?.isEmpty == true && fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Sample Game/data").path), "install: empty files and folders are created")
    check(read(paths, "_CommonRedist/vc/vcredist.exe") == nil, "install: Steam's redistributable installers are skipped")
    check(fake.requested.count == 8, "install: only the game's chunks were requested (\(fake.requested.count))")
    let acf = try? String(contentsOf: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/appmanifest_480.acf"), encoding: .utf8)
    check(acf?.contains("\"StateFlags\"\t\t\"4\"") == true && acf?.contains("\"installdir\"\t\t\"Sample Game\"") == true && acf?.contains("\"buildid\"\t\t\"777\"") == true, "install: an appmanifest is written the way Steam does")
    check(!fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/downloading/480").path), "install: the progress files are removed")
    check(fake.isClosed, "install: the connection to Steam is closed afterwards")
    let fractions = states.compactMap { state -> Double? in if case .downloading(let p) = state { return p.fraction } else { return nil } }
    check(states.first == .preparing("Asking Steam about Sample Game…") && !fractions.isEmpty && zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "install: progress only ever moves forward")
}

do {   // verify: a damaged file is repaired by fetching only the damaged chunks; an undamaged install fetches nothing
    let paths = freshPaths("verify-repair-chunks")
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    let first = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(first)
    check(first.state == .finished, "verify: the first install finishes (\(first.state))")
    let installed = paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Sample Game/data/levels/one.dat")
    let original = (try? Data(contentsOf: installed)) ?? Data()
    // Damage one byte in the chunk that covers 2000..<3000, and cut the end off another file.
    if let handle = try? FileHandle(forWritingTo: installed) { try? handle.seek(toOffset: 2100); try? handle.write(contentsOf: Data([original[2100] ^ 0xFF])); try? handle.close() }
    check((try? Data(contentsOf: installed)) != original, "verify: the file really is damaged now")
    // Without verify the install record says the depot is current: nothing is fetched, nothing is repaired (this is why Verify exists).
    var before = fake.requested.count
    let plain = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(plain)
    check(fake.requested.count == before && (try? Data(contentsOf: installed)) != original, "verify: a plain install of a current game fetches nothing")
    // With verify every file is checked against the manifest and only the damaged chunk comes again.
    before = fake.requested.count
    let check1 = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    check1.selection.verify = true
    run(check1)
    check(check1.state == .finished && (try? Data(contentsOf: installed)) == original, "verify: the damaged file is right again")
    check(fake.requested.count - before == 1, "verify: only the one damaged chunk was fetched (\(fake.requested.count - before))")
    // And a verify of an undamaged game fetches nothing.
    before = fake.requested.count
    let clean = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    clean.selection.verify = true
    run(clean)
    check(clean.state == .finished && fake.requested.count == before, "verify: an undamaged game fetches no chunk")
    // A file that is too long (an older version) is cut to the right length without fetching it.
    if let handle = try? FileHandle(forWritingTo: installed) { try? handle.seekToEnd(); try? handle.write(contentsOf: Data(repeating: 7, count: 500)); try? handle.close() }
    before = fake.requested.count
    let longer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    longer.selection.verify = true
    run(longer)
    check(fake.requested.count == before && (try? Data(contentsOf: installed)) == original, "verify: a file that is too long is cut to size with no download")
}


do {   // retries: a lost connection and a damaged answer are both tried again
    let paths = freshPaths("retry")
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    let firstChunk = ContentFixture.hex(depotA.files[0].data.isEmpty ? Data() : SteamCipher.sha1(sampleFiles[0].data.prefix(1000)))
    let secondChunk = ContentFixture.hex(SteamCipher.sha1(sampleFiles[0].data.subdata(in: 1000..<2000)))
    fake.failFirstRequests[firstChunk] = 2; fake.corruptFirstAnswers[secondChunk] = 1
    let installer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(installer)
    check(installer.state == .finished && read(paths, "Game.exe") == sampleFiles[0].data, "retry: a dropped connection and a damaged chunk are tried again and the install still succeeds")
    check(fake.requested.filter { $0 == firstChunk }.count == 3 && fake.requested.filter { $0 == secondChunk }.count == 2, "retry: exactly as many tries as needed")
}

do {   // a chunk that never arrives fails the download, with a reason, and keeps what it has
    let paths = freshPaths("giveup")
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    let bad = ContentFixture.hex(SteamCipher.sha1(sampleFiles[1].data.subdata(in: 2000..<3000)))
    fake.alwaysFail.insert(bad)
    let installer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    installer.retriesPerChunk = 3
    run(installer)
    if case .failed(let message) = installer.state { check(message.contains("stopped") && message.contains("resumed"), "give up: the failure says the download can be resumed (\(message))") } else { check(false, "give up: fails (\(installer.state))") }
    check(!fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/appmanifest_480.acf").path), "give up: no appmanifest, so the game does not show as installed")
    check(fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/downloading/480/done.bin").path), "give up: the finished chunks are remembered")
    // Later the server works again: the same download continues and asks only for what is missing.
    fake.alwaysFail = []
    let before = fake.requested.count
    let again = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(again)
    check(again.state == .finished && read(paths, "data/levels/one.dat") == sampleFiles[1].data, "resume: trying again finishes the install")
    check(fake.requested.count - before < 8 && fake.requested.count - before >= 1, "resume: only the missing chunks were fetched again (\(fake.requested.count - before) of 8)")
}

do {   // cancel part-way, then resume
    let paths = freshPaths("cancel")
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    fake.delay = 0.05
    let installer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    installer.parallelChunks = 1
    fake.onChunk = { count in if count == 4 { DispatchQueue.main.async { installer.cancel() } } }
    installer.start()
    spin(20) { installer.state.isFinal }
    check(installer.state == .cancelled, "cancel: stops (\(installer.state))")
    let doneOnDisk = (try? Data(contentsOf: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/downloading/480/done.bin")))?.count ?? 0
    check(doneOnDisk >= 4 && doneOnDisk < 32, "cancel: the chunks already done are remembered (\(doneOnDisk / 4) chunks)")
    check(!fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/appmanifest_480.acf").path), "cancel: the game is not recorded as installed")
    fake.onChunk = nil
    let before = fake.requested.count
    let again = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(again)
    check(again.state == .finished && read(paths, "Game.exe") == sampleFiles[0].data && read(paths, "data/levels/one.dat") == sampleFiles[1].data, "cancel: resuming finishes with every file correct")
    check(fake.requested.count - before <= 8 - doneOnDisk / 4 + 1, "cancel: the resumed run did not download everything again (\(fake.requested.count - before) chunks)")
}

do {   // changed game: a resume never mixes manifests
    let paths = freshPaths("changed")
    let v1 = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    v1.alwaysFail.insert(ContentFixture.hex(SteamCipher.sha1(sampleFiles[1].data.subdata(in: 2000..<3000))))
    let first = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: v1)
    first.retriesPerChunk = 1
    run(first)
    let newFiles = [ContentFixture.File(path: "Game.exe", data: ContentFixture.bytes(size: 2500, seed: 50)), ContentFixture.File(path: "data/levels/one.dat", data: ContentFixture.bytes(size: 3100, seed: 51))]
    let depotB = ContentFixture.makeDepot(id: 481, manifestID: 112, key: key, files: newFiles)
    let v2 = makeStore(appid: 480, name: "Sample Game", depots: [depotB])
    let second = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: v2)
    run(second)
    check(second.state == .finished && read(paths, "Game.exe") == newFiles[0].data && read(paths, "data/levels/one.dat") == newFiles[1].data, "update: a new version replaces the partial old one completely")
    check(v2.requested.count == 7, "update: everything in the new version was fetched (\(v2.requested.count) chunks)")
}

do {   // ownership
    let paths = freshPaths("owned")
    let depotShared = ContentFixture.makeDepot(id: 482, manifestID: 300, key: key, files: [.init(path: "extra.bin", data: ContentFixture.bytes(size: 1500, seed: 8))])
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA, depotShared])
    fake.notOwnedDepots = [482]
    let installer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(installer)
    check(installer.state == .finished && read(paths, "extra.bin") == nil && read(paths, "readme.txt") != nil, "owned: a depot the account does not own is skipped, the rest installs")
    let noneOwned = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    noneOwned.notOwnedDepots = [481]
    let blocked = SteamInstaller(appid: 480, name: "Sample Game", steamApps: freshPaths("owned2").steamApps, backend: noneOwned)
    run(blocked)
    if case .failed(let message) = blocked.state { check(message.contains("does not own"), "owned: with nothing owned it says so (\(message))") } else { check(false, "owned: fails when nothing is owned (\(blocked.state))") }
    let unknown = FakeContent()
    let missing = SteamInstaller(appid: 5, name: "Nope", steamApps: freshPaths("owned3").steamApps, backend: unknown)
    run(missing)
    if case .failed(let message) = missing.state { check(message.contains("does not list Nope"), "owned: an app Steam has no information for is reported (\(message))") } else { check(false, "owned: unknown app fails") }
}

do {   // other failures: no Windows depot, no content servers, no space
    let linuxOnly = makeStore(appid: 480, name: "Sample Game", depots: [depotA], extra: [481: "\t\t\t\"config\"\n\t\t\t{\n\t\t\t\t\"oslist\"\t\"linux\"\n\t\t\t}\n"])
    let a = SteamInstaller(appid: 480, name: "Sample Game", steamApps: freshPaths("linux").steamApps, backend: linuxOnly)
    run(a)
    check(a.state == .failed("Sample Game has no Windows version on Steam."), "failures: an app with no Windows depot says so")
    let noServers = makeStore(appid: 480, name: "Sample Game", depots: [depotA]); noServers.noServers = true
    let b = SteamInstaller(appid: 480, name: "Sample Game", steamApps: freshPaths("noservers").steamApps, backend: noServers)
    run(b)
    if case .failed(let message) = b.state { check(message.contains("content servers"), "failures: no content servers is reported (\(message))") } else { check(false, "failures: no servers fails") }
    let paths = freshPaths("space")
    let c = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: makeStore(appid: 480, name: "Sample Game", depots: [depotA]))
    c.freeSpaceOverride = { 100 << 20 }
    run(c)
    if case .failed(let message) = c.state { check(message.contains("not enough space") && message.contains("free"), "failures: too little space is reported before anything is written (\(message))") } else { check(false, "failures: no space fails") }
    check(!fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Sample Game/Game.exe").path), "failures: and nothing was written")
    let gone = makeStore(appid: 480, name: "Sample Game", depots: [depotA]); gone.appInfoFailure = SteamContentError(message: "The sign-in for downloads has expired. Sign in for downloads again.")
    let d = SteamInstaller(appid: 480, name: "Sample Game", steamApps: freshPaths("expired").steamApps, backend: gone)
    run(d)
    check(d.state == .failed("The sign-in for downloads has expired. Sign in for downloads again."), "failures: an expired download sign-in is reported as it is")
}

do {   // a depot shared from another app gets its manifest from that app
    let paths = freshPaths("shared")
    let shared = ContentFixture.makeDepot(id: 900, manifestID: 4444, key: key, files: [.init(path: "shared.dll", data: ContentFixture.bytes(size: 1200, seed: 9))])
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA], extra: [:])
    fake.apps[480]!.depots.append(SteamDepot(id: 900, fromApp: 70))
    fake.apps[70] = SteamAppInfo(appid: 70, name: "Other", installDirectory: "Other", buildID: "1", depots: [SteamDepot(id: 900, manifest: 4444)])
    fake.depots[900] = shared
    let installer = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(installer)
    check(installer.state == .finished && read(paths, "shared.dll") == shared.files[0].data, "shared depots: their files are installed with the game")
    check(fake.keyRequests.contains(900), "shared depots: the key was asked for through the app that shares it")
}

extension Data {
    init?(hexString: String) {
        var bytes: [UInt8] = []; var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
}

// MARK: - Installing DLC and other versions

print("--- install: DLC and branches")
func steamappsText(_ paths: LibraryPaths, _ file: String) -> String? { try? String(contentsOf: paths.steamApps.appendingPathComponent(file), encoding: .utf8) }
let dlcFile = ContentFixture.File(path: "dlc/extra.pak", data: ContentFixture.bytes(size: 2500, seed: 21))
let depotDLC = ContentFixture.makeDepot(id: 482, manifestID: 400, key: key, files: [dlcFile])
func dlcStore() -> FakeContent {
    makeStore(appid: 480, name: "Sample Game", depots: [depotA, depotDLC], extra: [482: "\t\t\t\"dlcappid\"\t\"950\"\n"])
}
func baseChunks(_ fake: FakeContent) -> Int { fake.requested.count }

do {   // DLC is left out unless it is asked for, added when it is, and skipped quietly when the account does not own it
    let none = freshPaths("dlc-none"); let fakeNone = dlcStore()
    let a = SteamInstaller(appid: 480, name: "Sample Game", steamApps: none.steamApps, backend: fakeNone)
    run(a)
    check(a.state == .finished && read(none, "dlc/extra.pak") == nil, "dlc: by default only the game's own files are installed")

    let all = freshPaths("dlc-all"); let fakeAll = dlcStore()
    let b = SteamInstaller(appid: 480, name: "Sample Game", steamApps: all.steamApps, backend: fakeAll)
    b.selection = SteamInstallSelection(dlc: .all)
    run(b)
    check(b.state == .finished && read(all, "dlc/extra.pak") == dlcFile.data && read(all, "Game.exe") == sampleFiles[0].data, "dlc: with DLC asked for its files are installed next to the game's")
    let record = steamappsText(all, "appmanifest_480.acf") ?? ""
    check(record.contains("\"482\"") && record.contains("\"dlcappid\"\t\t\"950\"") && record.contains("\"481\""), "dlc: the install record lists the DLC depot with its DLC app, as Steam's does")
    check(!record.contains("BetaKey"), "dlc: the public version carries no BetaKey")

    let denied = freshPaths("dlc-denied"); let fakeDenied = dlcStore(); fakeDenied.notOwnedDepots = [482]
    let c = SteamInstaller(appid: 480, name: "Sample Game", steamApps: denied.steamApps, backend: fakeDenied)
    c.selection = SteamInstallSelection(dlc: .all)
    run(c)
    check(c.state == .finished && read(denied, "Game.exe") != nil && read(denied, "dlc/extra.pak") == nil, "dlc: DLC the account does not own is skipped; the game still installs")
    check(!(steamappsText(denied, "appmanifest_480.acf") ?? "").contains("\"482\""), "dlc: and it is not claimed in the record")
}

do {   // adding DLC to an installed game fetches only the DLC; the game's depot is kept
    let paths = freshPaths("dlc-later"); let fake = dlcStore()
    let first = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(first)
    let before = fake.requested.count
    let later = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    later.selection = SteamInstallSelection(dlc: .all)
    run(later)
    let fetched = fake.requested.count - before
    check(later.state == .finished && read(paths, "dlc/extra.pak") == dlcFile.data && read(paths, "Game.exe") == sampleFiles[0].data, "dlc later: the DLC arrives and the game is intact")
    check(fetched == depotDLC.chunks.count, "dlc later: only the DLC's chunks were fetched (\(fetched) of \(depotDLC.chunks.count))")
    check(!fake.keyRequests.dropFirst(1).contains(481) || fake.keyRequests.filter { $0 == 481 }.count == 1, "dlc later: the game's depot was not asked about again")
    let record = steamappsText(paths, "appmanifest_480.acf") ?? ""
    check(record.contains("\"481\"") && record.contains("\"482\""), "dlc later: the record lists both depots")
    // Nothing new to fetch at all: it says so and still finishes.
    let again = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    again.selection = SteamInstallSelection(dlc: .all)
    let beforeAgain = fake.requested.count
    run(again)
    check(again.state == .finished && fake.requested.count == beforeAgain, "dlc later: installing the same thing again fetches nothing")
}

do {   // another version (branch): its own manifests and build id, a BetaKey in the record, and back to public again
    let paths = freshPaths("branch")
    let newData = ContentFixture.bytes(size: 3200, seed: 33)
    let betaFiles = [ContentFixture.File(path: "Game.exe", data: newData)]
    let betaDepot = ContentFixture.makeDepot(id: 481, manifestID: 112, key: key, files: betaFiles)
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    var info = fake.apps[480]!
    info.depots[0].branchManifests["beta"] = SteamDepotManifestEntry(gid: 112, size: betaDepot.totalSize, download: nil)
    info.branches.append(SteamBranch(name: "beta", buildID: "888"))
    fake.apps[480] = info
    fake.depots[481] = depotA
    let pub = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(pub)
    check(pub.state == .finished && read(paths, "Game.exe") == sampleFiles[0].data, "branch: the public version installs first")

    fake.depots[481] = betaDepot
    let beta = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    beta.selection = SteamInstallSelection(branch: "beta")
    run(beta)
    let record = steamappsText(paths, "appmanifest_480.acf") ?? ""
    check(beta.state == .finished && read(paths, "Game.exe") == newData, "branch: the beta's files replace the public ones (\(beta.state))")
    check(record.contains("\"buildid\"\t\t\"888\"") && record.contains("\"manifest\"\t\t\"112\""), "branch: the record carries the beta's build id and manifest")
    check(record.components(separatedBy: "\"BetaKey\"\t\t\"beta\"").count == 3, "branch: BetaKey is written to both config blocks, so Valve's client does not take it for the public version")
    check(beta.installInfo?.buildID == "888", "branch: the installer reports the branch's build")

    fake.depots[481] = depotA
    let back = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    run(back)
    let backRecord = steamappsText(paths, "appmanifest_480.acf") ?? ""
    check(back.state == .finished && read(paths, "Game.exe") == sampleFiles[0].data && !backRecord.contains("BetaKey") && backRecord.contains("\"buildid\"\t\t\"777\""), "branch: going back to public restores its files, build and drops the BetaKey")

    let missing = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    missing.selection = SteamInstallSelection(branch: "nonesuch")
    run(missing)
    if case .failed(let message) = missing.state { check(message.contains("nonesuch"), "branch: a version Steam does not list is refused by name (\(message))") } else { check(false, "branch: a missing version fails (\(missing.state))") }
}

// MARK: - Workshop

print("--- workshop")
do {   // what Steam answers for Workshop items
    let json = #"{"total":2,"publishedfiledetails":[{"result":1,"publishedfileid":"111","creator":"76561198000000001","consumer_appid":480,"title":"Big Mod","short_description":"Does [b]things[/b].","preview_url":"https://x/y.jpg","file_size":"2048","subscriptions":1500,"time_updated":1700000000,"hcontent_file":"4444","vote_data":{"score":0.9,"votes_up":90,"votes_down":10},"tags":[{"tag":"Maps"},{"tag":"x","display_name":"Gameplay"}]},{"result":9,"publishedfileid":"112"},{"result":1,"publishedfileid":"113","title":"Plain file","file_description":"[h1]Hi[/h1] there","file_url":"https://cdn/x/mod.zip","filename":"mods/mod.zip","hcontent_file":"0"}]}"#
    let reply = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    let items = SteamWorkshopParser.items(reply, appID: 480)
    check(items.count == 2 && items[0].id == 111 && items[1].id == 113, "workshop: items are read and a missing one (result 9) is left out")
    check(items[0].title == "Big Mod" && items[0].summary == "Does things." && items[0].fileSize == 2048 && items[0].subscriptions == 1500, "workshop: title, summary without BBCode, size, subscribers")
    check(items[0].contentManifest == 4444 && items[0].canDownload && items[0].rating == 0.9 && items[0].tags == ["Maps", "Gameplay"], "workshop: content manifest, rating, tags")
    check(items[0].updated == Date(timeIntervalSince1970: 1_700_000_000) && items[0].creator == 76561198000000001 && items[0].previewURL?.absoluteString == "https://x/y.jpg", "workshop: updated time, creator, picture")
    check(items[1].summary == "Hi there" && items[1].fileURL?.absoluteString == "https://cdn/x/mod.zip" && items[1].filename == "mods/mod.zip" && items[1].contentManifest == 0 && items[1].canDownload, "workshop: a plain-file item is downloadable from its address")
    check(items[1].appID == 480 && items[1].rating == nil, "workshop: the game defaults to the one asked for; no votes means no rating")
}

do {   // the account's subscriptions as Steam's client asks for them
    var one = PBWriter(); one.fixed64(1, 111); one.varint(3, 480); one.fixed64(4, 4444); one.varint(5, 2048)
    var two = PBWriter(); two.fixed64(1, 0)       // an entry with no id is ignored
    var answer = PBWriter(); answer.varint(1, 1); answer.message(2, one); answer.message(2, two); answer.varint(3, 7)
    if case .success(let list) = SteamWorkshopParser.subscribed(from: answer.data) {
        check(list.files == [SteamSubscribedFile(id: 111, appID: 480, subscribed: nil, updated: nil, manifest: 4444, size: 2048)] && list.total == 7, "workshop: subscribed files and the total are read")
    } else { check(false, "workshop: subscribed files are read") }
    var bad = PBWriter(); bad.varint(1, 2)
    if case .failure = SteamWorkshopParser.subscribed(from: bad.data) { check(true, "workshop: an error answer fails") } else { check(false, "workshop: an error answer fails") }
}

do {   // the record on disk, and downloading an item
    let paths = freshPaths("workshop-record")
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    SteamWorkshopFiles.record(.init(id: 111, size: 2048, manifest: 4444, updated: when), appID: 480, steamApps: paths.steamApps, subscribedBy: "42")
    SteamWorkshopFiles.record(.init(id: 222, size: 10, manifest: 5, updated: nil), appID: 480, steamApps: paths.steamApps, subscribedBy: "42")
    let found = SteamWorkshopFiles.installed(appID: 480, steamApps: paths.steamApps)
    check(found.count == 2 && found[111]?.manifest == 4444 && found[111]?.size == 2048 && found[111]?.updated == when, "workshop record: items are written and read back")
    let text = (try? String(contentsOf: SteamWorkshopFiles.recordURL(appID: 480, steamApps: paths.steamApps), encoding: .utf8)) ?? ""
    check(text.contains("\"AppWorkshop\"") && text.contains("\"WorkshopItemsInstalled\"") && text.contains("\"WorkshopItemDetails\"") && text.contains("\"subscribedby\"\t\t\"42\"") && text.contains("\"SizeOnDisk\"\t\t\"2058\""), "workshop record: the layout Steam's client uses")
    SteamWorkshopFiles.remove(item: 222, appID: 480, steamApps: paths.steamApps, subscribedBy: "42")
    check(SteamWorkshopFiles.installed(appID: 480, steamApps: paths.steamApps).keys.sorted() == [111], "workshop record: removing an item takes it out")
}

do {
    let modA = ContentFixture.File(path: "mod.json", data: ContentFixture.bytes(size: 900, seed: 31))
    let modB = ContentFixture.File(path: "textures/a.dds", data: ContentFixture.bytes(size: 5000, seed: 32))
    let paths = freshPaths("workshop-install")
    let fake = makeStore(appid: 480, name: "Sample Game", depots: [depotA])
    fake.depots[480] = ContentFixture.makeDepot(id: 480, manifestID: 777, key: key, files: [modA, modB])
    let a = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    a.workshop = .init(item: 12345, depot: 480, manifest: 777, updated: Date(timeIntervalSince1970: 1_700_000_000))
    a.ownerSteamID = String(76561197960265728 + 42)
    run(a)
    let folder = SteamWorkshopFiles.itemFolder(appID: 480, item: 12345, steamApps: paths.steamApps)
    check(a.state == .finished && (try? Data(contentsOf: folder.appendingPathComponent("mod.json"))) == modA.data && (try? Data(contentsOf: folder.appendingPathComponent("textures/a.dds"))) == modB.data, "workshop install: the item's files land in workshop/content/<app>/<item>")
    let record = SteamWorkshopFiles.installed(appID: 480, steamApps: paths.steamApps)[12345]
    check(record?.manifest == 777 && record?.size == 5900, "workshop install: the record lists the item with its manifest and size")
    check((steamappsText(paths, "workshop/appworkshop_480.acf") ?? "").contains("\"subscribedby\"\t\t\"42\""), "workshop install: subscribed by the account number")
    check(steamappsText(paths, "appmanifest_480.acf") == nil && !fm.fileExists(atPath: paths.steamApps.appendingPathComponent("common").path), "workshop install: the game's own record and folder are not touched")
    check(!fm.fileExists(atPath: paths.steamApps.appendingPathComponent("downloading/workshop_480_12345").path), "workshop install: the scratch folder is gone")
    // An update replaces the files: a file the new version no longer has is removed.
    fake.depots[480] = ContentFixture.makeDepot(id: 480, manifestID: 778, key: key, files: [.init(path: "mod.json", data: ContentFixture.bytes(size: 950, seed: 33))])
    let b = SteamInstaller(appid: 480, name: "Sample Game", steamApps: paths.steamApps, backend: fake)
    b.workshop = .init(item: 12345, depot: 480, manifest: 778, updated: nil)
    run(b)
    check(b.state == .finished && (try? Data(contentsOf: folder.appendingPathComponent("mod.json")))?.count == 950 && !fm.fileExists(atPath: folder.appendingPathComponent("textures/a.dds").path), "workshop update: the new files replace the old ones")
    check(SteamWorkshopFiles.installed(appID: 480, steamApps: paths.steamApps)[12345]?.manifest == 778, "workshop update: the record has the new manifest")
}

// MARK: - Packed chunks, binary KeyValues and the speed controller

// Made with the reference tools (xz --format=lzma, zstd -3): the same bytes Steam's content servers hold, wrapped the way Steam wraps them.
let vectorPlain: [UInt8] = [34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10,34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10,34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10,34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10,34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10,34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10]
let vectorVZip: [UInt8] = [86,90,97,111,90,206,188,93,0,0,1,0,0,17,18,73,199,51,213,65,39,221,209,101,8,114,130,23,77,164,177,62,199,241,82,116,254,176,95,191,74,87,201,31,192,25,80,137,20,53,30,142,168,238,209,120,16,131,73,164,165,50,136,77,255,143,218,152,15,249,20,225,212,101,198,69,119,178,180,127,238,175,156,105,91,89,97,63,118,35,91,34,150,172,231,223,166,255,186,47,96,0,111,90,206,188,224,1,0,0,122,118]
let vectorVZstd: [UInt8] = [86,83,90,97,111,90,206,188,40,181,47,253,100,224,0,205,2,0,4,5,34,73,110,115,116,97,108,108,83,99,114,105,112,116,34,10,123,10,9,34,82,101,103,105,115,116,114,121,34,10,9,123,10,9,9,34,72,75,69,89,95,76,79,67,65,76,95,77,65,67,72,73,78,69,92,92,83,79,70,84,87,65,82,69,92,92,69,120,97,109,112,108,101,34,10,9,125,10,125,10,1,0,80,227,164,134,40,250,197,152,249,111,90,206,188,224,1,0,0,0,0,0,0,122,115,118]

do {
    let plain = Data(vectorPlain)
    for (name, packed) in [("LZMA (VZip)", vectorVZip), ("Zstandard (VSZa)", vectorVZstd)] {
        let sealed = SteamCipher.encrypt(Data(packed), key: key, iv: Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }))!
        let out = SteamCipher.unpackChunk(sealed, key: key, originalSize: plain.count)
        check(out == plain, "chunks: \(name) unpacks to exactly the original")
        check(SteamCipher.unpackChunk(sealed, key: key, originalSize: plain.count + 1) == nil, "chunks: \(name) with the wrong expected size is refused")
        var damaged = packed; damaged[damaged.count / 2] ^= 0x55
        let sealedBad = SteamCipher.encrypt(Data(damaged), key: key, iv: Data(repeating: 3, count: 16))!
        check(SteamCipher.unpackChunk(sealedBad, key: key, originalSize: plain.count).map { $0 != plain } ?? true, "chunks: \(name) damaged is not accepted as the original")
    }
}

do {   // achievements: the schema's names and the unlock times, the answer's framing, and the public percentages
    func entry(_ type: UInt8, _ name: String, _ value: [UInt8]) -> [UInt8] { [type] + Array(name.utf8) + [0] + value }
    func text(_ name: String, _ value: String) -> [UInt8] { entry(1, name, Array(value.utf8) + [0]) }
    func object(_ name: String, _ inner: [UInt8]) -> [UInt8] { entry(0, name, inner + [8]) }
    let first = object("0", text("name", "ACH_FIRST") + object("display", object("name", text("english", "First steps") + text("german", "Erste")) + object("desc", text("english", "Walk")) + text("hidden", "0") + text("icon", "aaa") + text("icon_gray", "bbb")))
    let secret = object("1", text("name", "ACH_SECRET") + object("display", text("name", "#TOKEN") + text("hidden", "1") + text("icon", "ccc")))
    let counter = object("2", text("name", "STAT_NOT_AN_ACH"))
    let schema = Data(object("480", text("gameName", "Test") + object("stats", object("1", text("type", "4") + object("bits", first + secret)) + object("2", text("type", "1") + counter))) + [8])
    let found = SteamAchievementParser.achievements(schema: schema, blocks: [1: [1_700_000_000, 0]])
    check(found.count == 2 && found[0].apiName == "ACH_FIRST" && found[0].name == "First steps" && found[0].detail == "Walk", "achievements: names and descriptions come from the schema")
    check(found[0].unlocked == Date(timeIntervalSince1970: 1_700_000_000) && found[1].unlocked == nil, "achievements: the unlock time of each bit")
    check(found[1].hidden && found[1].name == "ACH_SECRET" && found[1].icon == "ccc" && found[0].iconGray == "bbb", "achievements: hidden, token names fall back to the api name, icons")
    check(found[0].iconURL(app: 480)?.lastPathComponent == "aaa.jpg" && SteamAchievement(apiName: "x", name: "x", detail: "", hidden: false, icon: "i", iconGray: "g", unlocked: nil, percent: nil).iconURL(app: 1)?.lastPathComponent == "g.jpg", "achievements: locked ones show the gray picture")
    check(SteamAchievement(apiName: "x", name: "x", detail: "", hidden: false, icon: "abc.jpg", iconGray: "def.jpg").iconURL(app: 7)?.absoluteString == "https://shared.fastly.steamstatic.com/community_assets/images/apps/7/def.jpg", "achievements: a picture name that already ends in .jpg is not given a second extension")
    check(SteamAchievementParser.achievements(schema: Data([1, 2, 3]), blocks: [:]).isEmpty, "achievements: a junk schema gives none")
    var answer = PBWriter(); answer.fixed64(1, 480); answer.varint(2, 1); answer.bytes(4, schema)
    var body = answer.data
    let blockBytes = Data([0x08, 0x01, 0x15, 0x00, 0xF1, 0x53, 0x65, 0x15, 0, 0, 0, 0])               // id 1; unlock_time (field 2, fixed32) twice
    var wrapped = Data([0x32, UInt8(blockBytes.count)]); wrapped.append(blockBytes); body.append(wrapped)
    if case .success(let reply) = SteamAchievementParser.reply(from: body) {
        check(reply.schema == schema && reply.blocks[1] == [1_700_000_000, 0], "achievements: the stats answer is read (schema, one fixed32 unlock time per bit)")
    } else { check(false, "achievements: the stats answer is read") }
    var failed = PBWriter(); failed.fixed64(1, 480); failed.varint(2, 2)
    if case .failure = SteamAchievementParser.reply(from: failed.data) { check(true, "achievements: an error answer fails") } else { check(false, "achievements: an error answer fails") }
    let shares = SteamAchievementParser.percentages(Data(#"{"achievementpercentages":{"achievements":[{"name":"A","percent":"12.5"},{"name":"B","percent":3.25}]}}"#.utf8))
    check(shares == ["A": 12.5, "B": 3.25], "achievements: public percentages, as numbers or strings")
    let sorted = steamSortAchievements([SteamAchievement(apiName: "l1", name: "", detail: "", hidden: false, unlocked: nil, percent: 5), SteamAchievement(apiName: "l2", name: "", detail: "", hidden: false, unlocked: nil, percent: 50),
                                        SteamAchievement(apiName: "u1", name: "", detail: "", hidden: false, unlocked: Date(timeIntervalSince1970: 10)), SteamAchievement(apiName: "u2", name: "", detail: "", hidden: false, unlocked: Date(timeIntervalSince1970: 20))])
    check(sorted.unlocked.map(\.apiName) == ["u2", "u1"] && sorted.locked.map(\.apiName) == ["l2", "l1"], "achievements: newest unlock first, commonest locked first")
}

do {   // unlocks while a game runs: Steam's stats file, the schema with positions, and what counts as new
    func entry(_ type: UInt8, _ name: String, _ value: [UInt8]) -> [UInt8] { [type] + Array(name.utf8) + [0] + value }
    func text(_ name: String, _ value: String) -> [UInt8] { entry(1, name, Array(value.utf8) + [0]) }
    func number(_ name: String, _ value: Int) -> [UInt8] { entry(2, name, (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
    func object(_ name: String, _ inner: [UInt8]) -> [UInt8] { entry(0, name, inner + [8]) }
    // cache { crc, 3 { data }, 4 { data, AchievementTimes { 0 = t, 2 = t } }, 25 { AchievementTimes { 1 = t } } }
    let file = Data(object("cache", number("crc", -5) + object("3", number("data", 24)) + object("4", number("data", 5) + object("AchievementTimes", number("0", 1_700_000_000) + number("2", 1_700_000_100)))
                    + object("25", object("AchievementTimes", number("1", 1_700_000_200)))) + [8])
    let times = SteamUserStatsFile.unlockTimes(file)
    check(times.count == 3 && times[SteamAchievementKey(stat: 4, bit: 0)] == 1_700_000_000 && times[SteamAchievementKey(stat: 4, bit: 2)] == 1_700_000_100 && times[SteamAchievementKey(stat: 25, bit: 1)] == 1_700_000_200, "stats file: the unlock time of each achievement bit, and plain stats are ignored")
    check(SteamUserStatsFile.unlockTimes(Data([1, 2, 3])).isEmpty && SteamUserStatsFile.unlockTimes(Data(object("other", number("x", 1)) + [8])).isEmpty, "stats file: junk or another file gives none")
    let known: Set<SteamAchievementKey> = [SteamAchievementKey(stat: 4, bit: 0)]
    let fresh = SteamUserStatsFile.newUnlocks(known: known, current: times, since: Date(timeIntervalSince1970: 1_700_000_050))
    check(fresh.map { $0.time } == [1_700_000_100, 1_700_000_200] && fresh[0].key == SteamAchievementKey(stat: 4, bit: 2), "unlocks: only what was not known, oldest first")
    let late = SteamUserStatsFile.newUnlocks(known: [], current: times, since: Date(timeIntervalSince1970: 1_700_000_150))
    check(late.map { $0.time } == [1_700_000_200], "unlocks: history Steam syncs into the file at the start (older than the game start) is not a new unlock")
    let schema = Data(object("77", text("gamename", "T") + object("stats", object("4", number("type_int", 4) + object("bits", object("2", text("name", "ACH_TWO") + object("display", object("name", text("english", "Two")) + object("desc", text("english", "Do two")) + text("icon", "aaa.jpg") + text("icon_gray", "bbb.jpg")))))
                                                      + object("25", object("bits", object("1", text("name", "ACH_ONE") + object("display", object("name", text("english", "One")) + number("hidden", 1))))))) + [8])
    let defs = SteamAchievementParser.definitions(schema: schema)
    check(defs.count == 2 && defs[0].stat == 4 && defs[0].bit == 2 && defs[0].achievement.name == "Two" && defs[0].achievement.icon == "aaa.jpg" && defs[1].stat == 25 && defs[1].achievement.hidden, "schema: each achievement with its stat and bit")
    check(SteamAchievementParser.achievements(schema: schema, blocks: [4: [0, 0, 1_700_000_100]]).first?.unlocked == Date(timeIntervalSince1970: 1_700_000_100), "schema: the list view still reads its unlock times")
}

do {   // the whole list from Steam's files on the device
    func entry(_ type: UInt8, _ name: String, _ value: [UInt8]) -> [UInt8] { [type] + Array(name.utf8) + [0] + value }
    func text(_ name: String, _ value: String) -> [UInt8] { entry(1, name, Array(value.utf8) + [0]) }
    func number(_ name: String, _ value: Int) -> [UInt8] { entry(2, name, (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
    func object(_ name: String, _ inner: [UInt8]) -> [UInt8] { entry(0, name, inner + [8]) }
    let paths = freshPaths("local-ach"); let steam = paths.driveC.appendingPathComponent("Program Files (x86)/Steam"); let stats = steam.appendingPathComponent("appcache/stats")
    try? fm.createDirectory(at: stats, withIntermediateDirectories: true)
    try? Data(object("9", object("stats", object("1", object("bits", object("0", text("name", "A0") + object("display", object("name", text("english", "Zero")))) + object("1", text("name", "A1") + object("display", object("name", text("english", "One")))))))) + [8]).write(to: stats.appendingPathComponent("UserGameStatsSchema_9.bin"))
    check(SteamLocalAchievements.load(steamFolder: steam, account: "5", appID: 9).map { $0.unlocked == nil } == [true, true], "local achievements: with no stats file everything is locked")
    try? Data(object("cache", object("1", number("data", 2) + object("AchievementTimes", number("1", 1_700_000_000)))) + [8]).write(to: stats.appendingPathComponent("UserGameStats_5_9.bin"))
    let local = SteamLocalAchievements.load(steamFolder: steam, account: "5", appID: 9)
    check(local.map(\.name) == ["Zero", "One"] && local[0].unlocked == nil && local[1].unlocked == Date(timeIntervalSince1970: 1_700_000_000), "local achievements: names from the schema, unlock times from the stats file")
    check(SteamLocalAchievements.load(steamFolder: steam, account: "5", appID: 10).isEmpty, "local achievements: a game with no schema file gives an empty list")
}

do {   // the overlay being asked for, as Steam's renderer log says it
    let log = "Sat Oct 17 21:53:07 2026 UTC - Showing overlay and saving cursor show count: 0\nSat Oct 17 21:53:07 2026 UTC - Saved Cursor: 00060056\nSat Oct 17 21:53:07 2026 UTC - 1 raw input devices to disable\n"
    check(SteamOverlayLog.showRequests(in: log) == 1, "overlay: one 'Showing overlay' line is one request")
    check(SteamOverlayLog.showRequests(in: "Game is using D3D9 or D3D9Ex, preparing to hook.\nAudio hooked\n") == 0 && SteamOverlayLog.showRequests(in: "") == 0, "overlay: the start-up lines are not a request")
    check(SteamOverlayLog.showRequests(in: log + log) == 2, "overlay: two requests are two")
}

do {   // friends: the list, the summaries, the fallback, the order and the words
    let list = (try? JSONSerialization.jsonObject(with: Data(#"{"friendslist":{"friends":[{"ulfriendid":"1","efriendrelationship":3},{"ulfriendid":"2","efriendrelationship":3},{"ulfriendid":"3","efriendrelationship":5},{"ulfriendid":"4","efriendrelationship":2},{"ulfriendid":"5","efriendrelationship":3}]}}"#.utf8))) as? [String: Any] ?? [:]
    check(SteamFriendsParser.friendIDs(list) == ["1", "2", "5"], "friends: only relationship 3 (friends) is listed, not ignored or pending ones")
    let summaries = (try? JSONSerialization.jsonObject(with: Data(#"{"players":[{"steamid":"1","personaname":"Ann","personastate":1,"avatarmedium":"https://x/a.jpg","lastlogoff":1700000000},{"steamid":"2","personaname":"Bob","personastate":1,"gameextrainfo":"Portal 2","gameid":"620"},{"steamid":"5","personaname":"Cy","personastate":0,"lastlogoff":1700000000},{"steamid":"6","personaname":"","personastate":1},{"steamid":"7","personaname":"Di","personastate":3}]}"#.utf8))) as? [String: Any] ?? [:]
    let found = SteamFriendsParser.friends(summaries: summaries)
    check(found.count == 4 && found.map(\.name) == ["Ann", "Bob", "Cy", "Di"], "friends: a player without a name is left out")
    check(found[1].isPlaying && found[1].gameName == "Portal 2" && found[1].gameID == 620 && found[0].avatarURL?.absoluteString == "https://x/a.jpg", "friends: the game, its id and the picture")
    let order = SteamFriendsParser.sorted(found).map(\.name)
    check(order == ["Bob", "Ann", "Di", "Cy"], "friends: playing first, then online by name, then offline (\(order))")
    check(found[1].status() == "In Portal 2" && found[0].status() == "Online" && found[3].status() == "Away", "friends: the words for playing, online and away")
    check(found[2].status(now: Date(timeIntervalSince1970: 1_700_000_000 + 7200)) == "Offline \u{00B7} 2 h ago" && SteamFriend(id: "9", name: "Z").status() == "Offline", "friends: how long ago an offline friend was seen, and offline when unknown")
    let links = (try? JSONSerialization.jsonObject(with: Data(#"{"accounts":[{"public_data":{"steamid":"1","persona_name":"Ann","sha_digest_avatar":"abc"}},{"public_data":{"steamid":"2","persona_name":""}}]}"#.utf8))) as? [String: Any] ?? [:]
    let fallback = SteamFriendsParser.friends(linkDetails: links)
    check(fallback.count == 1 && fallback[0].name == "Ann" && fallback[0].avatarURL?.absoluteString == "https://avatars.fastly.steamstatic.com/abc_medium.jpg" && fallback[0].state == 0, "friends: the fallback gives a name and a picture, no state")
}

do {   // a Zstandard block whose tables use the one-symbol (RLE) mode: the decoder used to refuse it
    let dir = ProcessInfo.processInfo.environment["STEAM_VECTORS"] ?? ""
    if let comp = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("zstd-rle-tables.zst")) {
        let out = Zstd.decompress(Array(comp), from: 0, to: comp.count, expectedSize: 128022)
        check(out.map { SteamCipher.sha1(Data($0)) == Data(hexString: "0ab5ff303418c08bb83e74424e08ec7353bfe386") } ?? false, "zstd: a block with one-symbol (RLE) tables decodes exactly")
    } else { print("skip: zstd RLE vector (set STEAM_VECTORS)") }
}

do {   // a package's product information: four bytes of package id, then binary KeyValues
    func entry(_ type: UInt8, _ name: String, _ value: [UInt8]) -> [UInt8] { [type] + Array(name.utf8) + [0] + value }
    let int32: (Int) -> [UInt8] = { v in (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    let appids = entry(0, "appids", entry(2, "0", int32(480)) + entry(2, "1", int32(481)) + [8])
    let depots = entry(0, "depotids", entry(2, "0", int32(482)) + [8])
    let body = entry(0, "1234", entry(1, "billingtype", Array("12".utf8) + [0]) + appids + depots + [8]) + [8]
    let info = SteamPackageInfo.parse(Data([0xD2, 0x04, 0, 0] + body), packageID: 1234)
    check(info == SteamPackageInfo(packageID: 1234, appIDs: [480, 481], depotIDs: [482]), "packages: the apps and depots a package grants are read")
    check(SteamPackageInfo.parse(Data([1, 2, 3]), packageID: 1) == nil && SteamBinaryKV.parse(Data([2, 65])) == nil, "packages: junk is refused")
    let wide = SteamBinaryKV.parse(Data(entry(5, "w", [0x48, 0, 0x69, 0, 0, 0]) + entry(7, "big", [1, 0, 0, 0, 0, 0, 0, 0]) + [8]))
    check(wide?["w"] as? String == "Hi" && wide?["big"] as? UInt64 == 1, "binary KeyValues: wide strings and 64-bit numbers")
}

do {   // the number of chunks in flight follows the rate
    var controller = ConcurrencyController(start: 12, floor: 6, ceiling: 48)
    var bytes: UInt64 = 0
    var now = Date(timeIntervalSince1970: 1_000_000)
    controller.observe(totalBytes: bytes, now: now)
    var seen = [controller.target]
    for second in stride(from: 0, to: 60, by: 3) {   // the link carries more as the number rises, up to 30 in flight
        now = now.addingTimeInterval(3); bytes += UInt64(min(controller.target, 30) * 1_000_000 * 3)
        controller.observe(totalBytes: bytes, now: now); seen.append(controller.target); _ = second
    }
    check(seen.max()! >= 24 && seen.max()! <= 48, "speed: it climbs while the rate keeps rising (peak \(seen.max()!))")
    var starved = ConcurrencyController(start: 12, floor: 6, ceiling: 48)
    var t = Date(timeIntervalSince1970: 2_000_000); var b: UInt64 = 0
    starved.observe(totalBytes: b, now: t)
    for _ in 0..<20 { t = t.addingTimeInterval(3); b += 3_000_000; starved.observe(totalBytes: b, now: t) }   // the rate never rises however many are open
    check(starved.target >= 6 && starved.target <= 18, "speed: it does not keep adding when more does not help (\(starved.target))")
}

do {   // which content server gets the next request
    func servers(_ n: Int) -> [SteamCDNServer] { (0..<n).map { SteamCDNServer(host: "cache\($0).test", https: true) } }
    let equal = SteamHostBook(hosts: servers(6))
    let first = (0..<6).compactMap { _ in equal.choose()?.host }
    check(Set(first).count == 6, "servers: untried servers each get a turn")

    let uneven = SteamHostBook(hosts: servers(3))
    for (name, rate) in [("cache0.test", 2.0), ("cache1.test", 40.0), ("cache2.test", 20.0)] {
        _ = uneven.choose(); uneven.finished(host: name, bytes: Int(rate * 1_048_576), seconds: 1, ok: true)
    }
    var tally: [String: Int] = [:]
    for _ in 0..<40 { if let h = uneven.choose() { tally[h.host, default: 0] += 1; uneven.finished(host: h.host, bytes: Int(1.0 * 1_048_576), seconds: 0.001, ok: true) } }
    check((tally["cache1.test"] ?? 0) > (tally["cache0.test"] ?? 0), "servers: the faster server gets more of the requests (\(tally))")

    let flaky = SteamHostBook(hosts: servers(2), startWith: 2)
    let a = flaky.choose()!; flaky.finished(host: a.host, bytes: 0, seconds: 0.1, ok: false)
    let picks = (0..<6).compactMap { _ -> String? in let h = flaky.choose(); if let h { flaky.finished(host: h.host, bytes: 1_000_000, seconds: 0.5, ok: true) }; return h?.host }
    check(!picks.contains(a.host), "servers: a server that just failed sits out for a while")

    let small = SteamHostBook(hosts: servers(4), startWith: 1)
    let many = (0..<20).compactMap { _ in small.choose()?.host }
    check(Set(many).count >= 2, "servers: more servers join in when a lot is waiting (\(Set(many).count))")

    let ranked = SteamCDN.parse(["servers": [
        ["host": "cache3.steamcontent.com", "https_support": "mandatory", "weighted_load": 90, "priority_class": 10],
        ["host": "cache1.steamcontent.com", "https_support": "mandatory", "weighted_load": 40, "priority_class": 10],
        ["host": "cache2.steamcontent.com", "https_support": "mandatory", "weighted_load": 70, "priority_class": 5],
        ["host": "cache4.steamcontent.com", "https_support": "mandatory", "weighted_load": 40, "priority_class": 10]]])
    check(ranked.map(\.host) == ["cache2.steamcontent.com", "cache1.steamcontent.com", "cache4.steamcontent.com", "cache3.steamcontent.com"], "content servers: ranked by Steam's priority class, then load, then the directory's order")
}

do {   // servers are taken site by site, so every site gets tried
    func named(_ names: [String]) -> [SteamCDNServer] { names.map { SteamCDNServer(host: "\($0).steamcontent.com", https: true) } }
    let book = SteamHostBook(hosts: named(["cache1-atl3", "cache2-atl3", "cache3-atl3", "cache4-atl3", "cache1-dfw2", "cache2-dfw2", "cache1-lax1"]))
    let firstThree = (0..<3).compactMap { _ in book.choose().map { SteamHostBook.site(of: $0.host) } }
    check(Set(firstThree) == ["atl3", "dfw2", "lax1"], "sites: the first requests go to different sites (\(firstThree))")
    check(SteamHostBook.site(of: "cache8-dfw2.steamcontent.com") == "dfw2" && SteamHostBook.site(of: "plain.example.net") == "plain.example.net", "sites: the place is read from the server's name")
    var far = named(["cache1-atl3", "cache1-dfw2"]); far[1].priority = 50
    check(SteamHostBook.spreadOverSites(far).map(\.host) == ["cache1-atl3.steamcontent.com", "cache1-dfw2.steamcontent.com"], "sites: a lower-priority site is kept after the best ones")
}

// MARK: - The real Steam servers (anonymous; opt in with STEAM_LIVE=1)

if ProcessInfo.processInfo.environment["STEAM_LIVE"] == "1" {
    print("--- live: installing Steam's free sample app (Spacewar, about 2 MB) anonymously")
    let paths = freshPaths("live")
    let backend = SteamCMBackend(logOn: .anonymous)
    let installer = SteamInstaller(appid: 480, name: "Spacewar", steamApps: paths.steamApps, backend: backend)
    run(installer, timeout: 120)
    check(installer.state == .finished, "live: the sample app installs from Steam's real servers (\(installer.state))")
    let exe = paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Spacewar/SteamworksExample.exe")
    check(((try? fm.attributesOfItem(atPath: exe.path)[.size] as? Int) ?? 0) == 382976 && (try? Data(contentsOf: exe))?.prefix(2) == Data("MZ".utf8), "live: SteamworksExample.exe has the right size and is a Windows program")
    check(!fm.fileExists(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Spacewar/_CommonRedist").path) || (try? fm.contentsOfDirectory(atPath: paths.driveC.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Spacewar/_CommonRedist").path))?.isEmpty == true, "live: redistributable installers were skipped")

    // The library chain: licence -> package -> apps -> product information -> the Windows games among them. An anonymous log-on has no licence
    // list of its own, so the package every anonymous user shares is fed in.
    print("--- live: from a package to the list of installable games")
    let library = SteamCMBackend(logOn: .anonymous)
    var games: [SteamAppInfo] = []
    var finished = false
    library.start { started in
        guard case .success = started else { finished = true; return }
        library.installableApps(for: [SteamLicense(packageID: 17906, accessToken: 0, flags: 0)]) { if case .success(let list) = $0 { games = list }; finished = true }
    }
    spin(150) { finished }
    let spacewar = games.first { $0.appid == 480 }
    check(games.count > 100, "live library: the package leads to many installable games (\(games.count))")
    check(spacewar?.name == "Spacewar" && spacewar?.installDirectory == "Spacewar" && (Int(spacewar?.buildID ?? "") ?? 0) > 0, "live library: name, install folder and build are read")
    check(spacewar?.launches.isEmpty == false && SteamDepotPlanner.sizes(app: spacewar!).download > 0, "live library: launch options and the download size are read")
    check(games.allSatisfy { $0.type == "game" }, "live library: only games, no tools, music or DLC")
    library.close()
}


// MARK: - Launch options: the number Valve's client is asked for
do {
    // Factorio's real entries: numbered 1, 2, 3 and 5 (no 0), a 64-bit and a 32-bit Windows one, Linux and macOS.
    let factorioText = "\"appinfo\"\n{\n\"appid\"\t\"427520\"\n\"common\"\n{\n\"name\"\t\"Factorio\"\n\"type\"\t\"Game\"\n}\n\"config\"\n{\n\"installdir\"\t\"Factorio\"\n\"launch\"\n{\n"
        + "\"1\"\n{\n\"executable\"\t\"bin/x64/Factorio.exe\"\n\"type\"\t\"default\"\n\"config\"\n{\n\"oslist\"\t\"windows\"\n\"osarch\"\t\"64\"\n}\n}\n"
        + "\"2\"\n{\n\"executable\"\t\"bin/Win32/Factorio.exe\"\n\"type\"\t\"default\"\n\"config\"\n{\n\"oslist\"\t\"windows\"\n\"osarch\"\t\"32\"\n}\n}\n"
        + "\"3\"\n{\n\"executable\"\t\"bin/x64/factorio\"\n\"type\"\t\"default\"\n\"config\"\n{\n\"oslist\"\t\"linux\"\n\"osarch\"\t\"64\"\n}\n}\n"
        + "\"5\"\n{\n\"executable\"\t\"factorio.app\"\n\"type\"\t\"default\"\n\"config\"\n{\n\"oslist\"\t\"macos\"\n}\n}\n}\n}\n}\n"
    let factorio = SteamAppInfoParser.parse(Data(factorioText.utf8), appid: 427520)
    check(factorio?.launches.map(\.key) == [1, 2, 3, 5], "launch entries keep their own numbers (\(factorio?.launches.map(\.key) ?? []))")
    check(factorio?.launches.first?.osarch == "64" && factorio?.launches[1].osarch == "32", "the processor width of each entry is read")
    check(SteamLaunchOption.dockDefaultKey(in: factorio?.launches ?? []) == 1, "Factorio: ask Valve's client for option 1, the 64-bit Windows entry")
    let forest = [SteamLaunchOption(executable: "TheForest.exe", oslist: "windows", key: 0), SteamLaunchOption(executable: "TheForest32.exe", type: "none", key: 1, osarch: "32"),
                  SteamLaunchOption(executable: "TheForestVR.exe", type: "vr", key: 3)]
    check(SteamLaunchOption.dockDefaultKey(in: forest) == 0, "an app whose Windows entry is number 0 still asks for 0 (The Forest)")
    check(SteamLaunchOption.dockDefaultKey(in: []) == nil, "no launch list at all: not known, so the caller fetches it")
    check(SteamLaunchOption.dockDefaultKey(in: [SteamLaunchOption(executable: "game.exe", oslist: "windows", key: 2, osarch: "32")]) == 0, "only a 32-bit entry: fall back to 0 rather than guess")
    let old = try? JSONDecoder().decode(SteamLaunchOption.self, from: Data(#"{"executable":"a.exe","arguments":"","type":"","oslist":"windows","description":""}"#.utf8))
    check(old?.key == nil && old?.osarch == "", "a saved launch list from before the number was kept still loads, with the number unknown")
    check(SteamLaunchOption.dockDefaultKey(in: old.map { [$0] } ?? []) == nil, "an old saved list is not mistaken for \"option 0\": it asks to be fetched fresh")
}


// MARK: - Steam Cloud, download only
do {
    print("--- Steam Cloud download")
    setenv("USER", "mobile", 1)          // the runtime's user on iOS; the code under test reads it like the runtime does
    // The messages (field numbers from Steam's service definitions).
    var req = PBWriter(); req.varint(1, 427520); req.varint(2, 0)
    check(SteamCloudMessages.changelistRequest(appID: 427520) == req.data, "cloud: the file-list request asks for the whole list of the app")
    func fileEntry(_ name: String, sha: Data, time: UInt64, size: Int, persist: UInt64 = 0, platforms: UInt64? = nil) -> PBWriter {
        var e = PBWriter(); e.string(1, name); e.bytes(2, sha); e.varint(3, time); e.varint(4, UInt64(size)); e.varint(5, persist); if let platforms { e.varint(6, platforms) }; return e
    }
    func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    let mainZip = Data((0..<5000).map { UInt8($0 % 251) }), startZip = Data("start".utf8)
    var listBody = PBWriter(); listBody.varint(1, 308)
    listBody.message(2, fileEntry("%WinAppDataRoaming%Factorio/saves/main.zip", sha: sha1(mainZip), time: 1_756_000_000, size: mainZip.count))
    listBody.message(2, fileEntry("%WinAppDataRoaming%Factorio/saves/start.zip", sha: sha1(startZip), time: 1_661_000_000, size: startZip.count, platforms: 1))
    listBody.message(2, fileEntry("config.ini", sha: Data(repeating: 1, count: 20), time: 5, size: 10))
    listBody.message(2, fileEntry("%WinAppDataRoaming%Factorio/saves/gone.zip", sha: Data(repeating: 2, count: 20), time: 5, size: 10, persist: 2))
    listBody.message(2, fileEntry("%WinAppDataRoaming%Factorio/saves/mac.zip", sha: Data(repeating: 3, count: 20), time: 5, size: 10, platforms: 2))
    listBody.message(2, fileEntry("%WinAppDataRoaming%../escape.zip", sha: Data(repeating: 4, count: 20), time: 5, size: 10))
    let list = SteamCloudMessages.parseChangelist(listBody.data)
    check(list?.currentChange == 308 && list?.files.count == 6, "cloud: the file list is read (\(list?.files.count ?? -1) files, change \(list?.currentChange ?? 0))")
    check(list?.files.filter { $0.isWanted }.count == 4, "cloud: deleted files and files for other platforms are not wanted (\(list?.files.filter { $0.isWanted }.count ?? -1) wanted)")
    var dl = PBWriter(); dl.varint(2, 99); dl.varint(3, 5000); dl.bytes(4, sha1(mainZip)); dl.varint(5, 1_756_000_000); dl.string(7, "steamcloud-us-east1.storage.googleapis.com"); dl.string(8, "/59/B7/x.dat"); dl.bool(9, true)
    var header = PBWriter(); header.string(1, "Expect"); header.string(2, "100-continue"); dl.message(10, header)
    let info = SteamCloudMessages.parseDownload(dl.data)
    check(info?.url?.absoluteString == "https://steamcloud-us-east1.storage.googleapis.com/59/B7/x.dat" && info?.headers["Expect"] == "100-continue" && info?.rawSize == 5000, "cloud: the download link, its headers and sizes are read")
    var evil = dl; evil = PBWriter(); evil.string(7, "evil.example/\u{0}@x"); evil.string(8, "/a")
    check(SteamCloudMessages.parseDownload(evil.data)?.url == nil, "cloud: a link whose host has odd characters is refused")
    check(SteamCloudMessages.parseChangelist(Data([0x0a, 0xff, 0xff])) == nil, "cloud: a damaged answer is refused")

    // Where files go.
    check(SteamCloudLocation.split("%WinAppDataRoaming%Factorio/saves/main.zip") == ("WinAppDataRoaming", "Factorio/saves/main.zip") && SteamCloudLocation.split("config.ini") == ("", "config.ini"), "cloud: names split into root and path")
    let driveC = root.appendingPathComponent("cloud-drive_c")
    try? fm.createDirectory(at: driveC.appendingPathComponent("users/Public"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: driveC.appendingPathComponent("users/mythic"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: driveC.appendingPathComponent("users/mobile"), withIntermediateDirectories: true)
    check(SteamCloudLocation.runtimeUserName(environment: [:]).isEmpty == false && SteamCloudLocation.runtimeUserName(environment: ["USER": "/var/mobile"]) == "mobile" && SteamCloudLocation.runtimeUserName(environment: ["USER": "mobile"]) == "mobile", "cloud: the runtime's user name is worked out like the runtime does ($USER, without a folder part)")
    check(SteamCloudLocation.windowsUser(in: driveC, runtimeUser: "mobile") == "mobile", "cloud: files go to the user the runtime runs as ('mobile'), not to the template's 'mythic'")
    check(SteamCloudLocation.windowsUser(in: driveC.appendingPathComponent("nothing-here"), runtimeUser: "mobile") == nil && SteamCloudLocation.windowsUser(in: driveC, runtimeUser: "Public") == nil && SteamCloudLocation.windowsUser(in: driveC, runtimeUser: "../x") == nil, "cloud: no users folder yet, or an unusable name: nothing is guessed")
    check(SteamCloudLocation.localURL(for: "%WinAppDataRoaming%Factorio/saves/main.zip", driveC: driveC, windowsUser: "mobile", installFolder: nil)?.path.hasSuffix("users/mobile/AppData/Roaming/Factorio/saves/main.zip") == true, "cloud: Roaming files go to AppData/Roaming")
    check(SteamCloudLocation.localURL(for: "config.ini", driveC: driveC, windowsUser: "mobile", installFolder: nil) == nil, "cloud: files in Steam's own per-game folder are left alone")
    check(["%WinAppDataRoaming%../x", "%WinAppDataRoaming%/etc/x", "%WinAppDataRoaming%a/../../x", "%WinAppDataRoaming%C:/x", "%MacHome%x"].allSatisfy { SteamCloudLocation.localURL(for: $0, driveC: driveC, windowsUser: "mobile", installFolder: nil) == nil }, "cloud: paths that leave the folder, drive letters and other systems' roots are refused")

    // The whole thing, against a stand-in for Steam.
    final class FakeCloud: SteamCloudTransport {
        var list: SteamCloudChangelist; var contents: [String: Data]; var served: [String: Data]
        private let lock = NSLock(); private var _fetches: [String] = []
        var fetches: [String] { get { lock.lock(); defer { lock.unlock() }; return _fetches } set { lock.lock(); _fetches = newValue; lock.unlock() } }
        init(list: SteamCloudChangelist, contents: [String: Data]) { self.list = list; self.contents = contents; served = contents }
        func changelist(appID: Int) async throws -> SteamCloudChangelist { list }
        func downloadInfo(appID: Int, fileName: String) async throws -> SteamCloudDownloadInfo {
            let f = list.files.first { $0.name == fileName }!
            return SteamCloudDownloadInfo(host: "h.example", path: "/" + fileName, https: true, headers: [:], fileSize: served[fileName]?.count ?? 0, rawSize: f.size, sha1: f.sha1, timestamp: f.timestamp, explicitDelete: false, encrypted: false)
        }
        func fetch(_ info: SteamCloudDownloadInfo) async throws -> Data { lock.lock(); _fetches.append(info.path); lock.unlock(); return served[String(info.path.dropFirst())] ?? Data() }
    }
    func packed(_ d: Data) -> Data {      // zlib form: 78 9c + raw deflate + 4 checksum bytes
        var out = Data(count: d.count + 1024)
        let n = out.withUnsafeMutableBytes { dst in d.withUnsafeBytes { src in compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB) } }
        return Data([0x78, 0x9c]) + out.prefix(n) + Data([0, 0, 0, 0])
    }
    let names = (main: "%WinAppDataRoaming%Factorio/saves/main.zip", start: "%WinAppDataRoaming%Factorio/saves/start.zip")
    let files = list!.files.filter { $0.name == names.main || $0.name == names.start }
    let saves = driveC.appendingPathComponent("users/mobile/AppData/Roaming/Factorio/saves")
    let cloud = FakeCloud(list: SteamCloudChangelist(currentChange: 308, files: files, pathPrefixes: []), contents: [names.main: mainZip, names.start: startZip])
    cloud.served[names.main] = packed(mainZip)          // served in the packed form
    var report = SteamCloudReport()
    do { report = try await SteamCloudSync.downloadMissing(appID: 427520, transport: cloud, driveC: driveC) } catch { check(false, "cloud: download ran (\(error))") }
    check(report.downloaded.count == 2 && report.failed.isEmpty, "cloud: both saves are downloaded (\(report.summary))")
    check((try? Data(contentsOf: saves.appendingPathComponent("main.zip"))) == mainZip, "cloud: a file served packed is unpacked, checked and saved")
    let stamp = (try? fm.attributesOfItem(atPath: saves.appendingPathComponent("start.zip").path)[.modificationDate]) as? Date
    check(stamp.map { Int($0.timeIntervalSince1970) } == 1_661_000_000, "cloud: the file keeps its cloud timestamp")
    check(!fm.fileExists(atPath: saves.appendingPathComponent("main.zip.porthole-part").path), "cloud: no half-written file is left behind")

    // Many small files are fetched several at a time, and every one still lands.
    final class SlowCloud: SteamCloudTransport {
        let list: SteamCloudChangelist; let served: [String: Data]
        private let lock = NSLock(); private var inFlight = 0; private(set) var peak = 0
        init(list: SteamCloudChangelist, served: [String: Data]) { self.list = list; self.served = served }
        func changelist(appID: Int) async throws -> SteamCloudChangelist { list }
        func downloadInfo(appID: Int, fileName: String) async throws -> SteamCloudDownloadInfo {
            let f = list.files.first { $0.name == fileName }!
            return SteamCloudDownloadInfo(host: "h.example", path: "/" + fileName, https: true, headers: [:], fileSize: f.size, rawSize: f.size, sha1: f.sha1, timestamp: f.timestamp, explicitDelete: false, encrypted: false)
        }
        func fetch(_ info: SteamCloudDownloadInfo) async throws -> Data {
            lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock()
            try? await Task.sleep(nanoseconds: 60_000_000)
            lock.lock(); inFlight -= 1; lock.unlock()
            return served[String(info.path.dropFirst())] ?? Data()
        }
        var maxAtOnce: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }
    var manyBody = PBWriter(); manyBody.varint(1, 9)
    var manyServed: [String: Data] = [:]
    for i in 0..<14 {
        let name = "%WinAppDataRoaming%Many/f\(i).bin", bytes = Data(repeating: UInt8(i + 1), count: 100)
        manyServed[name] = bytes; manyBody.message(2, fileEntry(name, sha: sha1(bytes), time: 5, size: 100))
    }
    let many = SlowCloud(list: SteamCloudMessages.parseChangelist(manyBody.data)!, served: manyServed)
    let manyDrive = root.appendingPathComponent("cloud-many/drive_c")
    try? fm.createDirectory(at: manyDrive.appendingPathComponent("users/mobile"), withIntermediateDirectories: true)
    let manyReport = (try? await SteamCloudSync.downloadMissing(appID: 1, transport: many, driveC: manyDrive)) ?? SteamCloudReport()
    check(manyReport.downloaded.count == 14 && manyReport.failed.isEmpty, "cloud: 14 files are all downloaded when fetched in parallel (\(manyReport.summary))")
    check(many.maxAtOnce > 1 && many.maxAtOnce <= 6, "cloud: files are fetched several at a time but no more than six (peak \(many.maxAtOnce))")
    check(manyReport.downloaded == (0..<14).map { "%WinAppDataRoaming%Many/f\($0).bin" }, "cloud: the report keeps the list's order")

    cloud.fetches = []
    report = (try? await SteamCloudSync.downloadMissing(appID: 427520, transport: cloud, driveC: driveC)) ?? SteamCloudReport()
    check(report.upToDate == 2 && cloud.fetches.isEmpty, "cloud: a second run downloads nothing (files already current)")

    // A newer local file is kept; an older different one is replaced and backed up; a corrupt download is never saved.
    try? Data("my newer world".utf8).write(to: saves.appendingPathComponent("start.zip"))
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: saves.appendingPathComponent("start.zip").path)
    try? Data("old copy".utf8).write(to: saves.appendingPathComponent("main.zip"))
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: saves.appendingPathComponent("main.zip").path)
    report = (try? await SteamCloudSync.downloadMissing(appID: 427520, transport: cloud, driveC: driveC)) ?? SteamCloudReport()
    check(report.keptNewerLocal == [names.start] && (try? Data(contentsOf: saves.appendingPathComponent("start.zip"))) == Data("my newer world".utf8), "cloud: a local file newer than the cloud copy is never replaced")
    check(report.downloaded == [names.main] && (try? Data(contentsOf: saves.appendingPathComponent("main.zip"))) == mainZip && (try? Data(contentsOf: saves.appendingPathComponent("main.zip.porthole-backup"))) == Data("old copy".utf8), "cloud: an older local file is replaced, and kept as a backup")

    try? fm.removeItem(at: saves.appendingPathComponent("main.zip"))
    cloud.served[names.main] = Data(repeating: 7, count: 5000)          // wrong bytes
    report = (try? await SteamCloudSync.downloadMissing(appID: 427520, transport: cloud, driveC: driveC)) ?? SteamCloudReport()
    check(report.failed == [names.main] && !fm.fileExists(atPath: saves.appendingPathComponent("main.zip").path), "cloud: bytes that do not match Steam's checksum are not saved")

    // The full list, including the odd entries, never writes outside the user's folders.
    let everything = FakeCloud(list: list!, contents: [:])
    try? fm.removeItem(at: saves)
    let before = (try? fm.contentsOfDirectory(atPath: driveC.path)) ?? []
    report = (try? await SteamCloudSync.downloadMissing(appID: 427520, transport: everything, driveC: driveC)) ?? SteamCloudReport()
    check(report.skipped.contains("config.ini") && report.skipped.contains("%WinAppDataRoaming%../escape.zip") && report.skipped.contains("%WinAppDataRoaming%Factorio/saves/gone.zip"), "cloud: unwanted and unsafe entries are skipped (\(report.skipped.count))")
    check(((try? fm.contentsOfDirectory(atPath: driveC.path)) ?? []) == before && !fm.fileExists(atPath: driveC.deletingLastPathComponent().appendingPathComponent("escape.zip").path), "cloud: nothing was written outside the Windows user's folders")

    // Names relative to a prefix table (the shape Steam uses to avoid repeating the folder): "main.zip" + prefix 1 = "%WinAppDataRoaming%Factorio/saves/main.zip".
    do {
        var pb = PBWriter(); pb.varint(1, 4)
        var f1 = fileEntry("main.zip", sha: sha1(mainZip), time: 1_756_000_000, size: mainZip.count); f1.varint(7, 1)
        var f2 = fileEntry("config.ini", sha: Data(repeating: 9, count: 20), time: 5, size: 10); f2.varint(7, 0)
        var f3 = fileEntry("start.zip", sha: sha1(startZip), time: 1_661_000_000, size: startZip.count, platforms: 0); f3.varint(7, 1)
        pb.message(2, f1); pb.message(2, f2); pb.message(2, f3)
        pb.string(4, ""); pb.string(4, "%WinAppDataRoaming%Factorio/saves/")
        let relative = SteamCloudMessages.parseChangelist(pb.data)
        check(relative?.pathPrefixes == ["", "%WinAppDataRoaming%Factorio/saves/"], "cloud: the prefix table is read")
        check(relative?.files.map { $0.fullName(prefixes: relative!.pathPrefixes) } == ["%WinAppDataRoaming%Factorio/saves/main.zip", "config.ini", "%WinAppDataRoaming%Factorio/saves/start.zip"], "cloud: a name relative to a prefix is completed; one with the empty prefix stays as it is")
        check(relative?.files[2].isWanted == true, "cloud: a file whose platforms are not given (0) counts as for Windows")
        let drive2 = root.appendingPathComponent("cloud-drive_c2")
        try? fm.createDirectory(at: drive2.appendingPathComponent("users/mythic"), withIntermediateDirectories: true)
        final class PrefixCloud: SteamCloudTransport {
            let list: SteamCloudChangelist; let contents: [String: Data]; var asked: [String] = []
            init(_ l: SteamCloudChangelist, _ c: [String: Data]) { list = l; contents = c }
            func changelist(appID: Int) async throws -> SteamCloudChangelist { list }
            func downloadInfo(appID: Int, fileName: String) async throws -> SteamCloudDownloadInfo {
                asked.append(fileName)
                let f = list.files.first { $0.fullName(prefixes: list.pathPrefixes) == fileName }!
                return SteamCloudDownloadInfo(host: "h.example", path: "/" + fileName, https: true, headers: [:], fileSize: f.size, rawSize: f.size, sha1: f.sha1, timestamp: f.timestamp, explicitDelete: false, encrypted: false)
            }
            func fetch(_ info: SteamCloudDownloadInfo) async throws -> Data { contents[String(info.path.dropFirst())] ?? Data() }
        }
        let pc = PrefixCloud(relative!, ["%WinAppDataRoaming%Factorio/saves/main.zip": mainZip, "%WinAppDataRoaming%Factorio/saves/start.zip": startZip])
        let r2 = (try? await SteamCloudSync.downloadMissing(appID: 427520, transport: pc, driveC: drive2)) ?? SteamCloudReport()
        let saves2 = drive2.appendingPathComponent("users/mobile/AppData/Roaming/Factorio/saves")
        check(r2.downloaded.count == 2 && (try? Data(contentsOf: saves2.appendingPathComponent("main.zip"))) == mainZip && r2.skipped == ["config.ini"], "cloud: files listed relative to a prefix are asked for by their full name and saved where they belong (\(r2.summary))")
        check(pc.asked == ["%WinAppDataRoaming%Factorio/saves/main.zip", "%WinAppDataRoaming%Factorio/saves/start.zip"], "cloud: Steam is asked for the full names (\(pc.asked))")
    }
}


// MARK: - The install record carries the game's language
do {
    print("--- install record language")
    let ours = "\"AppState\"\n{\n\t\"appid\"\t\t\"427520\"\n\t\"name\"\t\t\"Factorio\"\n\t\"InstalledDepots\"\n\t{\n\t\t\"427521\"\n\t\t{\n\t\t\t\"manifest\"\t\t\"1\"\n\t\t}\n\t}\n}\n"
    let fixed = SteamManifestLanguage.adding(to: ours)
    check(fixed?.contains("\"UserConfig\"\n\t{\n\t\t\"language\"\t\t\"english\"") == true && fixed?.contains("\"MountedConfig\"") == true, "language: both blocks are added to a record without them")
    check(fixed?.hasSuffix("\t}\n}\n") == true && fixed?.contains("\"InstalledDepots\"") == true && fixed.map { $0.filter { $0 == "{" }.count == $0.filter { $0 == "}" }.count } == true, "language: the record keeps its other content and stays balanced")
    check(fixed.flatMap { SteamVDF.parse($0) } .flatMap { ($0["appstate"] as? [String: Any]) } .flatMap { ($0["userconfig"] as? [String: Any])?["language"] as? String } == "english", "language: the record still reads as a valid Steam file, with the language in it")
    check(SteamManifestLanguage.adding(to: fixed ?? "") == nil, "language: adding twice changes nothing")
    check(SteamManifestLanguage.adding(to: "\"AppState\"\n{\n\t\"appid\"\t\t\"1\"\n\t\"UserConfig\"\n\t{\n\t\t\"language\"\t\t\"german\"\n\t}\n\t\"MountedConfig\"\n\t{\n\t\t\"language\"\t\t\"german\"\n\t}\n}\n") == nil, "language: a record that already says a language (even another one) is left alone")
    // The record as Valve's client leaves it: both blocks there, both empty.
    let valve = "\"AppState\"\n{\n\t\"appid\"\t\t\"427520\"\n\t\"LauncherPath\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe\"\n\t\"UserConfig\"\n\t{\n\t}\n\t\"MountedConfig\"\n\t{\n\t}\n}\n"
    let filled = SteamManifestLanguage.adding(to: valve)
    let parsedValve = filled.flatMap { SteamVDF.parse($0) }.flatMap { $0["appstate"] as? [String: Any] }
    check((parsedValve?["userconfig"] as? [String: Any])?["language"] as? String == "english" && (parsedValve?["mountedconfig"] as? [String: Any])?["language"] as? String == "english", "language: empty blocks written by Valve's client are filled in")
    check(filled.map { $0.components(separatedBy: "\"UserConfig\"").count == 2 && $0.components(separatedBy: "\"MountedConfig\"").count == 2 } == true && SteamManifestLanguage.adding(to: filled ?? "") == nil, "language: filling empty blocks does not duplicate them, and is done once")
    check(SteamManifestLanguage.adding(to: "\"AppState\"\n{\n\t\"UserConfig\"\n\t{\n\t\t\"language\"\t\t\"\"\n\t}\n}\n").map { $0.contains("\"language\"\t\t\"english\"") && $0.contains("\"MountedConfig\"") } == true, "language: an empty language value is replaced")
    check(SteamManifestLanguage.adding(to: "\"libraryfolders\"\n{\n}\n") == nil, "language: a file that is not an install record is left alone")
    let dir = root.appendingPathComponent("acf-lang"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? ours.write(to: dir.appendingPathComponent("appmanifest_427520.acf"), atomically: true, encoding: .utf8)
    check(SteamManifestLanguage.ensure(appID: 427520, steamApps: dir) == true && SteamManifestLanguage.ensure(appID: 427520, steamApps: dir) == false && SteamManifestLanguage.ensure(appID: 999, steamApps: dir) == false, "language: an existing record is repaired once on disk, and a missing one is no error")
}


// MARK: - Steam's own language in the prefix registry
do {
    print("--- steam client language")
    let withSteam = "WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000\n\n#arch=win64\n\n[Software\\\\Valve\\\\Steam] 1791016350\n#time=1dd5311ba9c1316\n\"RunningAppID\"=dword:00068600\n\"SteamPath\"=\"C:\\\\Program Files (x86)\\\\Steam\"\n\n[Software\\\\Valve\\\\Steam\\\\Apps\\\\1] 1\n#time=1\n\"Installed\"=dword:00000001\n\n"
    let set = SteamClientLanguage.adding(to: withSteam, now: 1791020000)
    check(set?.contains("[Software\\\\Valve\\\\Steam] 1791016350\n#time=1dd5311ba9c1316\n\"Language\"=\"english\"\n\"RunningAppID\"") == true, "steam registry: Language goes into the existing Steam key, after its time line")
    check(set.map { $0.contains("[Software\\\\Valve\\\\Steam\\\\Apps\\\\1] 1") && $0.contains("\"Installed\"=dword:00000001") && $0.hasSuffix("\n\n") } == true, "steam registry: other keys are untouched")
    check(SteamClientLanguage.adding(to: set ?? "") == nil, "steam registry: setting it twice changes nothing")
    check(SteamClientLanguage.adding(to: withSteam.replacingOccurrences(of: "\"RunningAppID\"", with: "\"Language\"=\"german\"\n\"RunningAppID\"")) == nil, "steam registry: another language already chosen is left alone")
    check(SteamClientLanguage.adding(to: withSteam.replacingOccurrences(of: "\"RunningAppID\"", with: "\"Language\"=\"\"\n\"RunningAppID\""))?.contains("\"Language\"=\"english\"") == true, "steam registry: an empty language is replaced")
    let bare = "WINE REGISTRY Version 2\n\n[Console] 1\n#time=1\n\"CloseOnExit\"=dword:00000001\n\n"
    let created = SteamClientLanguage.adding(to: bare, now: 1791020000)
    check(created?.contains("\n\n[Software\\\\Valve\\\\Steam] 1791020000\n#time=1dd531a3a19b000\n\"Language\"=\"english\"\n") == true && created?.hasPrefix(bare.trimmingCharacters(in: .newlines)) == true, "steam registry: a new Steam key is added with Wine's time lines when there is none")
    let prefixDir = root.appendingPathComponent("prefix-lang"); try? fm.createDirectory(at: prefixDir, withIntermediateDirectories: true)
    check(SteamClientLanguage.ensure(prefix: prefixDir) == false, "steam registry: a prefix without a registry yet is no error")
    try? withSteam.write(to: prefixDir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
    check(SteamClientLanguage.ensure(prefix: prefixDir) == true && SteamClientLanguage.ensure(prefix: prefixDir) == false && fm.fileExists(atPath: prefixDir.appendingPathComponent("user.reg.madeira-bak").path), "steam registry: written once on disk, with the one-time backup")
}


// MARK: - Shared Steam apps (Steamworks Common Redistributables)
do {
    print("--- shared apps")
    func depot(_ id: Int, from: Int? = nil) -> SteamDepot { var d = SteamDepot(id: id); d.fromApp = from; return d }
    check(SteamSharedApps.needed(by: [depot(311211), depot(228983, from: 228980), depot(228990, from: 228980)], gameID: 311210) == [228980], "shared apps: depots taken from app 228980 mean the game needs it")
    check(SteamSharedApps.needed(by: [depot(311211), depot(311212)], gameID: 311210).isEmpty, "shared apps: a game with only its own depots needs nothing")
    check(SteamSharedApps.needed(by: [depot(5, from: 4000)], gameID: 311210).isEmpty, "shared apps: another app's depots are not one Porthole provides")
    check(SteamSharedApps.needed(by: [depot(1, from: 311210)], gameID: 311210).isEmpty, "shared apps: a game's own id is not a dependency")
    let installedText = "\"AppState\"\n{\n\t\"appid\"\t\t\"228980\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"InstalledDepots\"\n\t{\n\t\t\"228983\"\n\t\t{\n\t\t\t\"manifest\"\t\t\"1\"\n\t\t}\n\t}\n}\n"
    check(SteamSharedApps.isInstalled(recordText: installedText), "shared apps: a finished record counts as installed")
    check(!SteamSharedApps.isInstalled(recordText: installedText.replacingOccurrences(of: "\"4\"", with: "\"6\"")), "shared apps: a record Steam left at 'update required' does not")
    check(!SteamSharedApps.isInstalled(recordText: "\"AppState\"\n{\n\t\"appid\"\t\t\"228980\"\n\t\"StateFlags\"\t\t\"4\"\n}\n"), "shared apps: a finished record with no depots does not")
    check(!SteamSharedApps.isInstalled(recordText: "garbage"), "shared apps: text that is not a record does not")
    let sharedDir = root.appendingPathComponent("shared-apps"); try? fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)
    check(!SteamSharedApps.isInstalled(appID: 228980, steamApps: sharedDir), "shared apps: no record file means not installed")
    try? installedText.write(to: sharedDir.appendingPathComponent("appmanifest_228980.acf"), atomically: true, encoding: .utf8)
    check(SteamSharedApps.isInstalled(appID: 228980, steamApps: sharedDir), "shared apps: the record file on disk is read")
}

try? fm.removeItem(at: root)

// MARK: - Branches and DLC

print("--- branches and DLC")
let betaKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
var secretGid = Data(); var gidValue: UInt64 = 424242; for _ in 0..<8 { secretGid.append(UInt8(gidValue & 0xFF)); gidValue >>= 8 }
let encryptedGid = SteamCipher.encryptECB(secretGid + Data(repeating: 8, count: 8), key: betaKey)!     // 8 data bytes + PKCS#7 padding, one block
let encryptedHex = encryptedGid.map { String(format: "%02x", $0) }.joined()
let branchText = """
"appinfo"
{
\t"appid"\t"900"
\t"common"
\t{
\t\t"name"\t"Branchy"
\t\t"type"\t"Game"
\t}
\t"config"
\t{
\t\t"installdir"\t"Branchy"
\t}
\t"extended"
\t{
\t\t"listofdlc"\t"901, 902,903"
\t}
\t"depots"
\t{
\t\t"901"
\t\t{
\t\t\t"manifests"
\t\t\t{
\t\t\t\t"public"
\t\t\t\t{
\t\t\t\t\t"gid"\t"1000"
\t\t\t\t\t"size"\t"5000"
\t\t\t\t\t"download"\t"2000"
\t\t\t\t}
\t\t\t\t"beta"
\t\t\t\t{
\t\t\t\t\t"gid"\t"2000"
\t\t\t\t\t"size"\t"6000"
\t\t\t\t\t"download"\t"2500"
\t\t\t\t}
\t\t\t}
\t\t\t"encryptedmanifests"
\t\t\t{
\t\t\t\t"secret"
\t\t\t\t{
\t\t\t\t\t"gid"\t"\(encryptedHex)"
\t\t\t\t\t"size"\t"7000"
\t\t\t\t\t"download"\t"3000"
\t\t\t\t}
\t\t\t}
\t\t}
\t\t"902"
\t\t{
\t\t\t"dlcappid"\t"950"
\t\t\t"manifests"
\t\t\t{
\t\t\t\t"public"\t"1100"
\t\t\t\t"beta"\t"2100"
\t\t\t}
\t\t}
\t\t"903"
\t\t{
\t\t\t"dlcappid"\t"951"
\t\t\t"manifests"
\t\t\t{
\t\t\t\t"public"\t"1200"
\t\t\t}
\t\t}
\t\t"branches"
\t\t{
\t\t\t"public"
\t\t\t{
\t\t\t\t"buildid"\t"10"
\t\t\t\t"timeupdated"\t"1700000000"
\t\t\t}
\t\t\t"beta"
\t\t\t{
\t\t\t\t"buildid"\t"20"
\t\t\t\t"description"\t"Next version"
\t\t\t}
\t\t\t"secret"
\t\t\t{
\t\t\t\t"buildid"\t"30"
\t\t\t\t"pwdrequired"\t"1"
\t\t\t}
\t\t}
\t}
}
"""
let branchy = SteamAppInfoParser.parse(Data(branchText.utf8), appid: 900)!
check(branchy.branches.map(\.name) == ["public", "beta", "secret"] && branchy.branches[0].buildID == "10" && branchy.buildID == "10", "branches: listed with public first; the public build id is still the app's")
check(branchy.branches[1].description == "Next version" && !branchy.branches[1].passwordRequired && branchy.branches[2].passwordRequired && branchy.branches[0].updated == Date(timeIntervalSince1970: 1_700_000_000), "branches: description, password flag and update time")
check(branchy.dlcApps == [950, 951] && branchy.listedDLC == [901, 902, 903], "dlc: the apps the depots belong to, and the app's own list of DLC")
check(branchy.depots[0].branchManifests["beta"]?.gid == 2000 && branchy.depots[0].manifest == 1000 && branchy.depots[0].size == 5000, "depots: every branch's manifest is kept; the public one is still in manifest/size")
check(branchy.depots[1].branchManifests["beta"]?.gid == 2100 && branchy.depots[1].branchManifests["public"]?.gid == 1100, "depots: the short form (branch = id) is read too")
check(branchy.depots[0].encryptedManifests["secret"]?.gid == encryptedGid && branchy.depots[0].encryptedManifests["secret"]?.size == 7000, "depots: an encrypted (password branch) manifest id is kept as bytes")
check(SteamBetaCrypto.decryptManifestID(encryptedGid, key: betaKey) == 424242, "branch password: the key reveals the manifest id")
check(SteamBetaCrypto.decryptManifestID(encryptedGid, key: Data(repeating: 9, count: 32)) != 424242 && SteamBetaCrypto.decryptManifestID(encryptedGid, key: Data(repeating: 1, count: 5)) == nil, "branch password: a wrong key gives something else; a short key is refused")

func summary(_ selection: SteamInstallSelection) -> [String] {
    SteamDepotPlanner.windowsDepots(app: branchy, selection: selection).map { "\($0.id):\($0.manifest.map(String.init) ?? "-")" }
}
check(summary(SteamInstallSelection()) == ["901:1000"], "planner: by default the public branch and the game's own files only")
check(summary(SteamInstallSelection(dlc: .all)) == ["901:1000", "902:1100", "903:1200"], "planner: all DLC adds their depots")
check(summary(SteamInstallSelection(dlc: .only([951]))) == ["901:1000", "903:1200"], "planner: chosen DLC only")
check(summary(SteamInstallSelection(branch: "beta", dlc: .all)) == ["901:2000", "902:2100"], "planner: a branch uses its own manifests; a depot it does not have is left out")
check(summary(SteamInstallSelection(branch: "secret")) == [], "planner: a password branch without its key has nothing to install")
check(summary(SteamInstallSelection(branch: "secret", branchKey: betaKey)) == ["901:424242"], "planner: the key turns the encrypted id into the branch's manifest")
check(SteamDepotPlanner.windowsDepots(app: branchy, selection: SteamInstallSelection(branch: "beta")).first?.size == 6000 && SteamDepotPlanner.sizes(app: branchy, selection: SteamInstallSelection(branch: "beta")).download == 2500, "planner: sizes follow the branch")
check(SteamDepotPlanner.sizes(app: branchy, selection: SteamInstallSelection(dlc: .all)).disk == 5000, "planner: DLC depots with no size listed add nothing to the estimate")

do {   // store info: reviews, the Deck rating, news
    let r = SteamStoreInfoParser.reviews(Data(#"{"success":1,"query_summary":{"review_score":9,"review_score_desc":"Overwhelmingly Positive","total_positive":462555,"total_negative":6069,"total_reviews":468624}}"#.utf8))
    check(r?.text == "Overwhelmingly Positive" && r?.score == 9 && r?.percent == 99, "reviews: Steam's words and the share of positive ones")
    check(SteamStoreInfoParser.reviews(Data(#"{"success":1,"query_summary":{"review_score":0,"review_score_desc":"No user reviews","total_reviews":0}}"#.utf8)) == nil, "reviews: a game with none shows nothing")
    check(SteamStoreInfoParser.reviews(Data("nope".utf8)) == nil, "reviews: junk is nothing")
    check(SteamStoreInfoParser.deck(Data(#"{"success":1,"results":{"appid":620,"resolved_category":3}}"#.utf8)) == .verified, "deck: 3 is verified")
    check(SteamStoreInfoParser.deck(Data(#"{"success":1,"results":{"resolved_category":2}}"#.utf8)) == .playable && SteamStoreInfoParser.deck(Data(#"{"success":1,"results":{"resolved_category":1}}"#.utf8)) == .unsupported, "deck: playable and unsupported")
    check(SteamStoreInfoParser.deck(Data(#"{"success":0}"#.utf8)) == .unknown && SteamStoreInfoParser.deck(Data(#"{"success":1,"results":{"resolved_category":9}}"#.utf8)) == .unknown, "deck: no answer or an odd number is not rated")
    let news = SteamStoreInfoParser.news(Data(#"{"appnews":{"appid":1,"newsitems":[{"gid":"1","title":"Old &amp; new","url":"https://x/a b","contents":"[h1]Patch[/h1] [img]{STEAM_CLAN_IMAGE}/1/a.png[/img] <b>Fixed</b> a crash &lt;3\n\n[list][*]one[/list]","feedlabel":"Steam","date":100},{"gid":"2","title":"Newer","url":"https://x/b","contents":"Hi","feedlabel":"RPS","date":200},{"gid":"3","title":"","contents":"no title","date":300}]}}"#.utf8))
    check(news.map(\.id) == ["2", "1"], "news: newest first, an item without a title is dropped")
    check(news[1].title == "Old & new" && news[1].summary == "Patch Fixed a crash <3 one" && news[1].url?.absoluteString == "https://x/a%20b", "news: tags, bbcode and images are removed, entities decoded, spaces in the link escaped (\(news[1].summary))")
    check(SteamStoreInfoParser.summary(String(repeating: "word ", count: 100), limit: 50).hasSuffix("\u{2026}") && SteamStoreInfoParser.summary("short", limit: 50) == "short", "news: long text is cut at a word with an ellipsis")
}


do {   // Workshop: Valve's finished-download cache for single-file items
    let text = SteamWorkshopFiles.ugcDataText(filename: "mymaps/1792273206.bsp", appID: 620, creator: 76561199181539405, sha1: "2da730894f92eb234458ec35857b1edfda335c58")
    let valve = "\"\"\n{\n\t\"filename\"\t\t\"mymaps/1792273206.bsp\"\n\t\"appid\"\t\t\"620\"\n\t\"creator\"\t\t\"76561199181539405\"\n\t\"sha1\"\t\t\"2da730894f92eb234458ec35857b1edfda335c58\"\n}\n"
    check(text == valve, "ugc cache: data.vdf is byte for byte what Valve's client wrote")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ugc-seed-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("item.bsp")
    try? Data("abc".utf8).write(to: file)
    check(SteamWorkshopFiles.sha1Hex(of: file) == "a9993e364706816aba3e25717850c26c9cd0d89d", "ugc cache: sha1 of a file")
    check(!SteamWorkshopFiles.isSeeded(filename: "mymaps/x.bsp", handle: 55, steamRoot: root, account: "7"), "ugc cache: nothing there yet")
    check(SteamWorkshopFiles.seedReferenced(file: file, filename: "mymaps/x.bsp", handle: 55, appID: 644, creator: 9, steamRoot: root, account: "7"), "ugc cache: seeding works")
    let folder = SteamWorkshopFiles.referencedFolder(steamRoot: root, account: "7", handle: 55)
    check(folder.path.hasSuffix("userdata/7/ugc/referenced/55") && (try? Data(contentsOf: folder.appendingPathComponent("mymaps/x.bsp"))) == Data("abc".utf8), "ugc cache: the file is in userdata/<acct>/ugc/referenced/<handle>/")
    let data = (try? String(contentsOf: folder.appendingPathComponent("data.vdf"), encoding: .utf8)) ?? ""
    check(data.contains("\"appid\"\t\t\"644\"") && data.contains("\"sha1\"\t\t\"a9993e364706816aba3e25717850c26c9cd0d89d\"") && SteamWorkshopFiles.isSeeded(filename: "mymaps/x.bsp", handle: 55, steamRoot: root, account: "7"), "ugc cache: data.vdf names the app, creator and sha1")
    check(!SteamWorkshopFiles.seedReferenced(file: file, filename: "../x.bsp", handle: 55, appID: 1, creator: 1, steamRoot: root, account: "7") && !SteamWorkshopFiles.seedReferenced(file: file, filename: "a.bsp", handle: 0, appID: 1, creator: 1, steamRoot: root, account: "7") && !SteamWorkshopFiles.seedReferenced(file: file, filename: "a.bsp", handle: 5, appID: 1, creator: 1, steamRoot: root, account: "0"), "ugc cache: no folder escape, no handle 0, no unknown account")
    try? FileManager.default.removeItem(at: root)
}


do {   // Workshop record: a single-file item is written the way Steam's client writes it (manifest -1 and ugchandle)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-single-\(UUID().uuidString)")
    let apps = root.appendingPathComponent("steamapps")
    try? FileManager.default.createDirectory(at: apps.appendingPathComponent("workshop"), withIntermediateDirectories: true)
    SteamWorkshopFiles.record(.init(id: 7, size: 10, manifest: 900, updated: nil, ugcHandle: 900), appID: 730, steamApps: apps, subscribedBy: "42")
    SteamWorkshopFiles.record(.init(id: 8, size: 10, manifest: 55, updated: nil), appID: 730, steamApps: apps, subscribedBy: "42")
    let text = (try? String(contentsOf: SteamWorkshopFiles.recordURL(appID: 730, steamApps: apps), encoding: .utf8)) ?? ""
    check(text.contains("\t\t\t\"manifest\"\t\t\"-1\"\n\t\t\t\"ugchandle\"\t\t\"900\""), "workshop record: a single-file item has manifest -1 and its ugchandle in the details")
    check(text.contains("\"latest_manifest\"\t\t\"-1\"") && text.contains("\"latest_manifest\"\t\t\"55\""), "workshop record: latest_manifest follows the same rule, a depot item keeps its manifest")
    let back = SteamWorkshopFiles.installed(appID: 730, steamApps: apps)
    check(back[7]?.ugcHandle == 900 && back[7]?.manifest == 900 && back[8]?.ugcHandle == 0 && back[8]?.manifest == 55, "workshop record: the handle is read back, a depot item has none")
    try? FileManager.default.removeItem(at: root)
}



print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
