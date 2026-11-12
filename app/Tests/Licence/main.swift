import Foundation
import CryptoKit

var failed = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok:   \(name)" : "FAIL: \(name)"); if !ok { failed += 1 } }

let key = SymmetricKey(size: .bits256)
let other = SymmetricKey(size: .bits256)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86_400
let id = "76561198000000001"

let r = LosslessLicence.issue(steamID: id, now: t0, key: key)
check("a fresh receipt is valid for the whole week", LosslessLicence.status(of: r, now: t0, signedInSteamID: id, key: key) == .valid(daysLeft: 7))
check("... for 6 more days after a day", LosslessLicence.status(of: r, now: t0.addingTimeInterval(day + 60), signedInSteamID: id, key: key) == .valid(daysLeft: 6))
check("... while signed out or offline (the receipt's own account)", LosslessLicence.status(of: r, now: t0.addingTimeInterval(3 * day), signedInSteamID: nil, key: key) == .valid(daysLeft: 4))
check("... and on its last day", { if case .valid(let d) = LosslessLicence.status(of: r, now: t0.addingTimeInterval(6.5 * day), signedInSteamID: id, key: key) { return d <= 1 } else { return false } }())
check("it runs out after the week", LosslessLicence.status(of: r, now: t0.addingTimeInterval(7 * day + 60), signedInSteamID: id, key: key) == .expired)
check("a receipt for another account does not open for this one", LosslessLicence.status(of: r, now: t0, signedInSteamID: "76561198000000002", key: key) == .otherAccount)

var edited = r; edited.verifiedAt = t0.addingTimeInterval(5 * day)
check("a changed date does not verify", LosslessLicence.status(of: edited, now: t0.addingTimeInterval(5 * day), signedInSteamID: id, key: key) == .tampered)
edited = r; edited.steamID = "76561198000000009"
check("a changed account does not verify", LosslessLicence.status(of: edited, now: t0, signedInSteamID: nil, key: key) == .tampered)
check("a receipt made with another device's key does not verify", LosslessLicence.status(of: r, now: t0, signedInSteamID: id, key: other) == .tampered)
var wrongApp = r; wrongApp.appID = 440
check("a receipt for another app does not verify", LosslessLicence.status(of: wrongApp, now: t0, signedInSteamID: id, key: key) == .tampered)

// the clock
let used = LosslessLicence.seen(r, now: t0.addingTimeInterval(5 * day), key: key)
check("using it moves lastSeen forward and stays valid", used.lastSeen == t0.addingTimeInterval(5 * day) && LosslessLicence.status(of: used, now: t0.addingTimeInterval(5 * day), signedInSteamID: id, key: key) == .valid(daysLeft: 2))
check("a clock set back by days after a use is noticed", LosslessLicence.status(of: used, now: t0.addingTimeInterval(2 * day), signedInSteamID: id, key: key) == .tampered)
check("a small step back (time zone, correction) is not", LosslessLicence.status(of: used, now: t0.addingTimeInterval(5 * day - 3600), signedInSteamID: id, key: key) == .valid(daysLeft: 3))
check("seen never moves lastSeen back", LosslessLicence.seen(used, now: t0, key: key).lastSeen == used.lastSeen)
var future = LosslessLicence.issue(steamID: id, now: t0.addingTimeInterval(30 * day), key: key); future.lastSeen = future.verifiedAt; future.mac = LosslessLicence.mac(future, key: key)
check("a licence 'verified' in the future is refused", LosslessLicence.status(of: future, now: t0, signedInSteamID: id, key: key) == .tampered)
check("a receipt survives being saved and read", { let d = try! JSONEncoder().encode(r); let back = try! JSONDecoder().decode(LosslessLicence.Receipt.self, from: d); return back == r && LosslessLicence.status(of: back, now: t0, signedInSteamID: id, key: key) == .valid(daysLeft: 7) }())

// the sealed file
let dll = Data((0..<4096).map { UInt8($0 & 0xff) })
let secret = SymmetricKey(size: .bits256)
let sealed = try! LosslessLicence.seal(dll, deviceSecret: secret, steamID: id)
check("the sealed file does not contain the file", sealed.count > dll.count && sealed.range(of: dll.prefix(64)) == nil)
check("it opens for the same device and account", (try? LosslessLicence.open(sealed, deviceSecret: secret, steamID: id)) == dll)
check("it does not open for another account", (try? LosslessLicence.open(sealed, deviceSecret: secret, steamID: "76561198000000002")) == nil)
check("it does not open on another device", (try? LosslessLicence.open(sealed, deviceSecret: SymmetricKey(size: .bits256), steamID: id)) == nil)
var broken = sealed; broken[broken.count / 2] ^= 0x01
check("a changed byte is noticed", (try? LosslessLicence.open(broken, deviceSecret: secret, steamID: id)) == nil)
check("sealing twice gives different bytes (a new nonce each time)", (try! LosslessLicence.seal(dll, deviceSecret: secret, steamID: id)) != sealed)
check("sha256 is the usual one", LosslessLicence.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

// the shaders in the DLL (only when the owner's own copy is on this Mac: ~/Desktop/Lossless-Scaling-copy/Lossless.dll, never in the repository)
check("garbage gives no shaders", LosslessShaders.extract(from: Data(repeating: 0x41, count: 4096)).isEmpty && LosslessShaders.extract(from: Data()).isEmpty)
check("a PE header with no resources gives no shaders", LosslessShaders.extract(from: Data([0x4d, 0x5a] + [UInt8](repeating: 0, count: 200))).isEmpty)
let copy = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Lossless-Scaling-copy/Lossless.dll")
if let dllData = try? Data(contentsOf: copy) {
    let shaders = LosslessShaders.extract(from: dllData)
    check("the owner's DLL: 202 shaders", shaders.count == 202)
    check("... ids 101 to 302", shaders.keys.min() == 101 && shaders.keys.max() == 302)
    // the ids lsfg-vk 1.0.0 names for the 3.1 frame generation
    let wanted = [255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 282, 283, 290, 291, 292, 293, 298, 299, 300, 301, 302]
    check("... every id of the frame generation passes is there", wanted.allSatisfy { shaders[$0] != nil })
    check("... each one is a DXBC container whose recorded size matches the blob", shaders.values.allSatisfy { b in b.prefix(4) == Data("DXBC".utf8) && b.count >= 32 && Int(b[b.startIndex + 24]) | Int(b[b.startIndex + 25]) << 8 | Int(b[b.startIndex + 26]) << 16 | Int(b[b.startIndex + 27]) << 24 <= b.count })
    if let box = LosslessShaders.container(from: dllData) {
        // read it back the way the engine does
        func le(_ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(box[box.startIndex + o + $1]) << (8 * $1) } }
        var ok = box.prefix(4) == Data("LSFG".utf8) && le(4) == 1 && le(8) == shaders.count
        var o = 12, seen = 0
        while o + 8 <= box.count, seen < le(8) { let id = le(o), n = le(o + 4); o += 8; ok = ok && shaders[id]?.count == n && box.subdata(in: (box.startIndex + o)..<(box.startIndex + o + n)) == shaders[id]; o += n; seen += 1 }
        check("the file for the engine reads back to the same shaders", ok && seen == shaders.count && o == box.count)
    } else { check("the file for the engine can be made", false) }
    print("      (\(shaders.count) shaders, \(shaders.values.reduce(0) { $0 + $1.count } / 1024) KB)")
} else { print("skip: no Lossless.dll copy on this Mac") }

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
