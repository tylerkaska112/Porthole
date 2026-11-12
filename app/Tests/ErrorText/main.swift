import Foundation

var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func url(_ code: Int) -> Error { NSError(domain: NSURLErrorDomain, code: code) }
func cocoa(_ code: Int) -> Error { NSError(domain: NSCocoaErrorDomain, code: code) }
func posix(_ code: Int32) -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

struct Mine: LocalizedError { var errorDescription: String? { "Steam says this game is not released yet." } }
struct Plain: Error {}
enum NoWords: Error { case oops }

// What a person must never be shown.
func jargon(_ s: String) -> Bool {
    s.contains("NSURLErrorDomain") || s.contains("NSCocoaErrorDomain") || s.contains("NSPOSIXErrorDomain") || s.contains("operation couldn\u{2019}t be completed") || s.contains("operation couldn't be completed")
}

do {   // the network
    let offline = ErrorText.plain(url(NSURLErrorNotConnectedToInternet))
    check(offline.contains("no internet connection") && offline.contains("Wi-Fi") && !jargon(offline), "network: offline says so and what to check")
    check(ErrorText.plain(url(NSURLErrorDataNotAllowed)).contains("Mobile data is off"), "network: mobile data off is named")
    check(ErrorText.plain(url(NSURLErrorTimedOut)).contains("too long") && ErrorText.plain(url(NSURLErrorTimedOut)).contains("Try again"), "network: a time-out says to try again")
    check(ErrorText.plain(url(NSURLErrorCannotFindHost)).contains("VPN") && ErrorText.plain(url(NSURLErrorDNSLookupFailed)).contains("address"), "network: an address that cannot be found points at a VPN or a blocking network")
    check(ErrorText.plain(url(NSURLErrorCannotConnectToHost)).contains("could not be reached"), "network: a refused connection")
    check(ErrorText.plain(url(NSURLErrorNetworkConnectionLost)).contains("dropped"), "network: a dropped connection")
    check(ErrorText.plain(url(NSURLErrorServerCertificateUntrusted)).contains("date and time"), "network: a certificate problem points at the clock and a VPN")
    check(ErrorText.plain(url(NSURLErrorCancelled)) == "Cancelled.", "network: cancelled is just cancelled")
    check(ErrorText.plain(url(NSURLErrorBadServerResponse)).contains("try again later"), "network: a bad answer is the server's trouble")
    check(ErrorText.plain(url(NSURLErrorCannotParseResponse)).contains("answer"), "network: an answer that cannot be read")
}

do {   // storage and files
    check(ErrorText.plain(cocoa(NSFileWriteOutOfSpaceError)).contains("not enough free storage") && ErrorText.plain(posix(ENOSPC)).contains("not enough free storage"), "storage: out of space, from Cocoa and from POSIX, says how to make room")
    check(ErrorText.plain(cocoa(NSFileWriteNoPermissionError)).contains("not allowed") && ErrorText.plain(posix(EACCES)).contains("not allowed"), "files: no permission")
    check(ErrorText.plain(cocoa(NSFileReadNoSuchFileError)).contains("not there any more") && ErrorText.plain(posix(ENOENT)).contains("not there any more"), "files: a file that is gone")
    check(ErrorText.plain(cocoa(NSFileReadCorruptFileError)).contains("damaged"), "files: a damaged file")
    check(ErrorText.plain(cocoa(NSUserCancelledError)) == "Cancelled.", "files: the person cancelled")
    check(ErrorText.plain(posix(EROFS)).contains("only be read"), "files: a read-only place")
    check(ErrorText.plain(posix(EIO)).contains("restart the device"), "storage: an I/O error says to restart if it repeats")
}

do {   // the rest
    check(ErrorText.plain(CancellationError()) == "Cancelled.", "cancellation")
    let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
    check(ErrorText.plain(decoding).contains("not in the form this version of Porthole expects"), "a server answer in a form the app does not know says to update")
    check(ErrorText.plain(Mine()) == "Steam says this game is not released yet.", "the app's own errors are passed through unchanged")
    let unknown = NSError(domain: "SomeFrameworkErrorDomain", code: 77, userInfo: [NSLocalizedDescriptionKey: "The operation couldn\u{2019}t be completed. (SomeFrameworkErrorDomain error 77.)"])
    let g = ErrorText.plain(unknown)
    check(!jargon(g) && g.contains("Something went wrong") && g.contains("SomeFramework 77") && g.contains("send a report"), "an unknown system error: honest, with its number, without the boilerplate (\(g))")
    let described = NSError(domain: "SomeFrameworkErrorDomain", code: 5, userInfo: [NSLocalizedDescriptionKey: "The certificate is expired"])
    check(ErrorText.plain(described) == "The certificate is expired. (SomeFramework 5)", "an unknown error with a real description keeps it and adds the number")
    check(!jargon(ErrorText.plain(Plain())) && !jargon(ErrorText.plain(NoWords.oops)), "a Swift error with no description is not shown as system jargon")
    check(ErrorText.plain(NoWords.oops).contains("Something went wrong"), "a Swift error with no words says something went wrong and what to do")
}

do {   // HTTP
    check(ErrorText.http(404).contains("moved or removed") && ErrorText.http(403).contains("Signing in") && ErrorText.http(429).contains("Wait"), "http: 404, 403 and 429 in words")
    check(ErrorText.http(503).contains("not on your side") && ErrorText.http(500).contains("500"), "http: a server error is not the person's fault, and keeps its number")
    check(ErrorText.plain(url(NSURLErrorTimedOut), doing: "The download").hasPrefix("The download failed."), "doing: says what was being done")
}

do {   // nothing comes out empty or shouting
    let all: [Error] = [url(-1), url(-999), url(-1009), cocoa(0), cocoa(4), posix(0), Plain(), NoWords.oops, Mine(), CancellationError(), NSError(domain: "X", code: 1)]
    check(all.allSatisfy { !ErrorText.plain($0).isEmpty && !jargon(ErrorText.plain($0)) }, "every kind of error gives some words and none of the system's jargon")
}

print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
