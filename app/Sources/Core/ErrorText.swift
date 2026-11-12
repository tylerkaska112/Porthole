// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// An error in words a person can act on.
///
/// The system's own text for an error is for programmers: "The operation couldn't be completed. (NSURLErrorDomain error -1009.)". Everything the app shows about a failure that came
/// from the system (the network, the disk, a file) goes through `plain`, which says what happened, what is probably behind it and what to try, in one or two sentences, with the
/// error's number kept at the end for a report. An error the app made itself already has a sentence of its own (`LocalizedError`) and is passed through as it is.
enum ErrorText {
    /// The error as a sentence. Never empty.
    static func plain(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if let decoding = error as? DecodingError { return explain(decoding) }
        let ns = error as NSError
        if let mapped = mapped(domain: ns.domain, code: ns.code, error: ns) { return mapped }
        // One of ours (not a system error): it has a sentence of its own.
        if !isSystemDomain(ns.domain), let own = error as? LocalizedError, let text = own.errorDescription, !text.isEmpty { return text }
        return generic(ns)
    }

    /// "<what was being done> failed: <plain reason>" for places that have no sentence of their own about what was attempted.
    static func plain(_ error: Error, doing: String) -> String {
        let reason = plain(error)
        return "\(doing) failed. \(reason)"
    }

    /// What an HTTP answer's status number means for a person.
    static func http(_ status: Int) -> String {
        switch status {
        case 400: return "The server did not understand the request (400). Updating Porthole may fix it."
        case 401, 403: return "The server did not allow it (\(status)). Signing in again may fix it."
        case 404: return "The server does not have what was asked for (404). It may have been moved or removed."
        case 408: return "The server took too long to answer (408). Try again in a moment."
        case 429: return "Too many requests were sent in a short time (429). Wait a few minutes and try again."
        case 500...599: return "The server is having trouble (\(status)). This is not on your side: try again later."
        default: return "The server answered with an unexpected status (\(status)). Try again later."
        }
    }

    // MARK: Behind it

    private static func isSystemDomain(_ domain: String) -> Bool {
        ["NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain", "kCFErrorDomainCFNetwork", "NSStreamSocketSSLErrorDomain", "NSMachErrorDomain"].contains(domain)
    }

    private static func explain(_ error: DecodingError) -> String {
        "The answer from the server was not in the form this version of Porthole expects. Updating Porthole may fix it; if it does not, send a report from Settings."
    }

    private static let offline = "There is no internet connection. Check Wi-Fi or mobile data, then try again."

    static func mapped(domain: String, code: Int, error: NSError) -> String? {
        switch domain {
        case NSURLErrorDomain:
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
                return code == NSURLErrorDataNotAllowed
                    ? "Mobile data is off for Porthole, and there is no Wi-Fi. Turn on Wi-Fi, or allow Porthole to use mobile data in Settings \u{203A} Cellular, then try again."
                    : offline
            case NSURLErrorTimedOut:
                return "The server took too long to answer. Try again in a moment, or on a better connection."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "The server's address could not be found. If the internet works for other apps, the server may be down, or a VPN, ad blocker or school or work network may be blocking it. Try again later or on another network."
            case NSURLErrorCannotConnectToHost:
                return "The server could not be reached. It may be down, or something on your network is blocking it. Try again later or on another network."
            case NSURLErrorNetworkConnectionLost:
                return "The connection dropped part-way. Try again; a steadier connection helps."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return "A secure connection to the server could not be made. Check that the date and time on this device are right, and that a VPN or a school or work network is not interfering, then try again."
            case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorZeroByteResource:
                return "The server gave an answer Porthole could not use. It may be having trouble: try again later."
            case NSURLErrorCancelled:
                return "Cancelled."
            case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable:
                return "The server does not have this file any more. It may have been moved or removed."
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
                return "The address is not one Porthole can use. Check it for typing mistakes."
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "The server is not using a secure connection, which iOS does not allow here."
            case NSURLErrorBackgroundSessionInUseByAnotherProcess, NSURLErrorBackgroundSessionWasDisconnected, NSURLErrorBackgroundSessionRequiresSharedContainer:
                return "iOS stopped the background download. Open Porthole and start it again."
            default: return nil
            }
        case NSCocoaErrorDomain:
            switch code {
            case NSFileWriteOutOfSpaceError:
                return "There is not enough free storage on this device. Free some space (Settings \u{203A} General \u{203A} iPhone Storage) and try again."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "Porthole is not allowed to use that file or folder. If it is in Files or on an external drive, give Porthole access to it again."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "A file Porthole needs is not there any more. It may have been moved or deleted: choose it again, or add it again."
            case NSFileReadCorruptFileError, NSPropertyListReadCorruptError, NSPropertyListReadUnknownVersionError:
                return "A file is damaged or in a form Porthole does not know. If it is a download, download it again."
            case NSFileWriteVolumeReadOnlyError:
                return "That place can only be read, not written to. Choose another place."
            case NSFileWriteFileExistsError:
                return "A file with that name is already there."
            case NSFileWriteInvalidFileNameError, NSFileReadInvalidFileNameError:
                return "The name of the file has a character it cannot have. Rename it and try again."
            case NSFileLockingError:
                return "The file is in use by something else. Wait a moment and try again."
            case NSUserCancelledError:
                return "Cancelled."
            case NSFileReadUnknownError, NSFileWriteUnknownError:
                return "The device could not read or write the file. If this repeats, restart the device."
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(code) {
            case ENOSPC: return "There is not enough free storage on this device. Free some space (Settings \u{203A} General \u{203A} iPhone Storage) and try again."
            case EACCES, EPERM: return "Porthole is not allowed to do that to the file or folder."
            case ENOENT: return "A file or folder Porthole needs is not there any more."
            case EROFS: return "That place can only be read, not written to."
            case EIO: return "The device's storage reported an error while reading or writing. If this repeats, restart the device."
            case ENOMEM: return "The device ran out of memory. Close other apps and try again."
            case EMFILE, ENFILE: return "Too many files are open at once. Close Porthole fully and open it again."
            case ECONNREFUSED: return "The server refused the connection. It may be down: try again later."
            case ETIMEDOUT: return "The server took too long to answer. Try again in a moment."
            case ENETDOWN, ENETUNREACH, EHOSTUNREACH: return offline
            case ECONNRESET, EPIPE: return "The connection dropped part-way. Try again."
            default: return nil
            }
        default:
            return nil
        }
    }

    /// An error with no better words: say so honestly, drop the system's boilerplate and keep the number for a report.
    static func generic(_ ns: NSError) -> String {
        var text = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // "The operation couldn\u{2019}t be completed. (SomeDomain error 5.)" says nothing: keep only the domain and number.
        let boilerplate = ["The operation couldn\u{2019}t be completed.", "The operation couldn't be completed."]
        if let b = boilerplate.first(where: { text.hasPrefix($0) }) {
            let tail = String(text.dropFirst(b.count)).trimmingCharacters(in: .whitespaces)
            text = tail.hasPrefix("(") ? "" : tail
        }
        let code = "\(shortDomain(ns.domain)) \(ns.code)"
        if text.isEmpty { return "Something went wrong that Porthole has no better words for (\(code)). Try again; if it repeats, send a report from Settings and mention this number." }
        let end = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? "" : "."
        return "\(text)\(end) (\(code))"
    }

    private static func shortDomain(_ domain: String) -> String {
        domain.replacingOccurrences(of: "NSURLErrorDomain", with: "network")
            .replacingOccurrences(of: "NSCocoaErrorDomain", with: "file")
            .replacingOccurrences(of: "NSPOSIXErrorDomain", with: "system")
            .replacingOccurrences(of: "ErrorDomain", with: "")
    }
}
