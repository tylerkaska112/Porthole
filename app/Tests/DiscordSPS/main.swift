import Foundation
// usage: sps-test <in.h264> <out.h264>: replaces the first SPS of an Annex B file with DiscordSPS.rewriteVUI's version and writes the result.
let args = CommandLine.arguments
guard args.count == 3, let input = FileManager.default.contents(atPath: args[1]) else { print("usage: sps-test in.h264 out.h264"); exit(2) }
let bytes = [UInt8](input)
var starts: [(at: Int, len: Int)] = []
var i = 0
while i + 3 <= bytes.count {
    if bytes[i] == 0, bytes[i + 1] == 0 {
        if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
        if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
    }
    i += 1
}
var out = Data()
var done = false
for (n, s) in starts.enumerated() {
    let from = s.at + s.len, to = n + 1 < starts.count ? starts[n + 1].at : bytes.count
    let nal = Data(bytes[from..<to])
    if !done, nal[0] & 0x1F == 7 {
        guard let new = DiscordSPS.rewriteVUI(nal, colour: ProcessInfo.processInfo.environment["SPS_COLOUR"] == "1") else { print("FAIL: the SPS could not be rewritten"); exit(1) }
        print("SPS \(nal.count) bytes -> \(new.count) bytes")
        out.append(contentsOf: [0, 0, 1]); out.append(new); done = true
    } else { out.append(contentsOf: [0, 0, 1]); out.append(nal) }
}
guard done else { print("FAIL: no SPS in the file"); exit(1) }
FileManager.default.createFile(atPath: args[2], contents: out)
