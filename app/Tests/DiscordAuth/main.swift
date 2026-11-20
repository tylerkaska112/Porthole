import Foundation
import Security
import CryptoKit

var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let crypto = try! DiscordRemoteAuthCrypto()

// MARK: the public key
let encoded = crypto.encodedPublicKey
let der = Data(base64Encoded: encoded)!
check(der.count == 294, "the encoded public key is a 294-byte SubjectPublicKeyInfo (RSA-2048)")
check(Array(der.prefix(24)) == DiscordRemoteAuthCrypto.spkiPrefix, "it starts with the RSA SubjectPublicKeyInfo header")
let pkcs1 = der.suffix(from: 24)
let rebuilt = SecKeyCreateWithData(Data(pkcs1) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)
check(rebuilt != nil, "the bytes after the header are a valid PKCS#1 public key")

// MARK: what Discord would send, encrypted to that key
func serverEncrypt(_ plain: Data) -> String {
    let pub = rebuilt!
    var error: Unmanaged<CFError>?
    let cipher = SecKeyCreateEncryptedData(pub, .rsaEncryptionOAEPSHA256, plain as CFData, &error)! as Data
    return cipher.base64EncodedString()
}
let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
let decryptedNonce = try! crypto.decrypt(base64: serverEncrypt(nonce))
check(decryptedNonce == nonce, "a nonce encrypted to the public key decrypts to itself")

let expectedProof = Data(SHA256.hash(data: nonce)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
let proof = DiscordRemoteAuthCrypto.proof(forNonce: decryptedNonce)
check(proof == expectedProof, "the proof is base64url of the nonce's SHA-256")
check(!proof.contains("=") && !proof.contains("+") && !proof.contains("/"), "the proof has no padding and no + or /")
check(proof.count == 43, "a SHA-256 proof is 43 characters")

// MARK: the person who scanned
let user = DiscordRemoteAuthCrypto.scannedUser(from: try! crypto.decrypt(base64: serverEncrypt(Data("1234567890:0:abcdef:test_account".utf8))))
check(user == .init(id: "1234567890", discriminator: "0", avatar: "abcdef", username: "test_account"), "the scanned person's id, avatar and name are read out")
check(user?.display == "test_account", "a new-style name (discriminator 0) shows without #0")
let old = DiscordRemoteAuthCrypto.scannedUser(from: Data("1:4242:av:old".utf8))
check(old?.display == "old#4242", "an old-style name keeps its discriminator")
check(DiscordRemoteAuthCrypto.scannedUser(from: Data("not enough parts".utf8)) == nil, "a payload of the wrong shape is refused")
let colon = DiscordRemoteAuthCrypto.scannedUser(from: Data("1:0:av:name:with:colons".utf8))
check(colon?.username == "name:with:colons", "a name that holds colons stays whole")

// MARK: the token
let token = "mfa.fake-token-for-test_ABC.123"
let back = try! crypto.decrypt(base64: serverEncrypt(Data(token.utf8)))
check(String(data: back, encoding: .utf8) == token, "an encrypted token decrypts to itself")

// MARK: errors
var rejected = false
do { _ = try crypto.decrypt(base64: "!!!not base64!!!") } catch DiscordRemoteAuthError.badPayload { rejected = true } catch {}
check(rejected, "text that is not base64 is a bad payload")
rejected = false
do { _ = try crypto.decrypt(base64: Data(repeating: 7, count: 256).base64EncodedString()) } catch DiscordRemoteAuthError.decrypt { rejected = true } catch {}
check(rejected, "cipher text that was not made for this key does not decrypt")
let other = try! DiscordRemoteAuthCrypto()
rejected = false
do { _ = try other.decrypt(base64: serverEncrypt(nonce)) } catch DiscordRemoteAuthError.decrypt { rejected = true } catch {}
check(rejected, "another client's key cannot read it")
check(DiscordRemoteAuthCrypto.qrURL(fingerprint: "abc123")?.absoluteString == "https://discord.com/ra/abc123", "the QR code is Discord's ra link")

print(failed == 0 ? "\nall passed" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
