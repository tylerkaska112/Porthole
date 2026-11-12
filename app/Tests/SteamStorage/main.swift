import Foundation

var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func throwsError(_ body: () throws -> Void) -> Error? { do { try body(); return nil } catch { return error } }

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("ssd-test-\(UUID().uuidString)")
try! fm.createDirectory(at: base, withIntermediateDirectories: true)
func dir(_ name: String) -> URL { let u = base.appendingPathComponent(name); try! fm.createDirectory(at: u, withIntermediateDirectories: true); return u }

// MARK: the drive's identity marker
let drive = dir("Drive")
let id = try! SteamStorageIdentity.register(root: drive)
check(UUID(uuidString: id) != nil, "registering a folder writes a UUID marker")
check(throwsError { try SteamStorageIdentity.verify(id, root: drive) } == nil, "the marker verifies")
check(try! SteamStorageIdentity.register(root: drive) == id, "registering the same folder again adopts the marker, never overwrites it")
if case SteamStorageError.unavailable(.identityMismatch)? = throwsError({ try SteamStorageIdentity.verify(UUID().uuidString, root: drive) }) {
    check(true, "another library's id does not verify against this folder")
} else { check(false, "another id must be an identity mismatch") }
let otherDrive = dir("Other")
check(throwsError { try SteamStorageIdentity.verify(id, root: otherDrive) } != nil, "a different disk mounted at the old place (no marker) is refused, never adopted")
check(!FileManager.default.fileExists(atPath: otherDrive.appendingPathComponent(".madeira-library-id").path), "and no marker is written to it behind the person's back")
try! fm.removeItem(at: drive)
check(throwsError { try SteamStorageIdentity.verify(id, root: drive) } != nil, "an unplugged drive (folder gone) fails the check")
try! fm.createDirectory(at: drive, withIntermediateDirectories: true)
try! Data(id.utf8).write(to: drive.appendingPathComponent(".madeira-library-id"))
check(throwsError { try SteamStorageIdentity.verify(id, root: drive) } == nil, "plugging it back in with its marker works again")

// MARK: paths never leave the library
check(throwsError { _ = try SteamStoragePath.native("steamapps/common/Game", root: drive) } == nil, "a normal game path is accepted")
for bad in ["../escape", "steamapps/../../escape", "a/./b", "C:/x", "a//b", ""] {
    check(throwsError { _ = try SteamStoragePath.components(bad) } != nil, "the path \"\(bad)\" is refused")
}
let outside = dir("Outside")
try! fm.createSymbolicLink(at: drive.appendingPathComponent("steamapps-link"), withDestinationURL: outside)
check(throwsError { _ = try SteamStoragePath.native("steamapps-link/common", root: drive) } != nil, "a symlink inside the library that points out of it is refused")
check(try! SteamStoragePath.windows("steamapps/common/G", library: SteamStorageLibrary(id: id, name: "SSD", bookmark: Data([1]))) == "E:\\steamapps\\common\\G", "a game path on the SSD is an E: path")

// MARK: the catalog
var catalog = SteamStorageCatalog()
let file = base.appendingPathComponent("catalog/steam-storage.json")
let library = SteamStorageLibrary(id: id, name: "My SSD", bookmark: Data([1, 2, 3]))
check(throwsError { try catalog.register(SteamStorageLibrary(id: "not-a-uuid", name: "x", bookmark: Data([1]))) } != nil, "a library id that is not a UUID is refused")
check(throwsError { try catalog.register(SteamStorageLibrary(id: UUID().uuidString, name: "x", bookmark: nil)) } != nil, "a library without a bookmark is refused")
try! catalog.transaction(file: file) { try $0.register(library) }
check(catalog.external == library, "the library is registered and saved")
check(throwsError { try catalog.transaction(file: file) { try $0.register(SteamStorageLibrary(id: UUID().uuidString, name: "second", bookmark: Data([1]))) } } != nil, "a second, different drive is refused (one SSD library)")

let location = try! SteamStorageLocation(libraryID: id, relativePath: "steamapps/common/Spacewar")
try! catalog.transaction(file: file) { try $0.assign(SteamStorageAssignment(appID: 480, location: location, name: "Spacewar", installed: false)) }
check(catalog.assignments[480]?.location == location, "a game is assigned to the SSD")
let other = try! SteamStorageLocation(libraryID: id, relativePath: "steamapps/common/Elsewhere")
check(throwsError { try catalog.transaction(file: file) { try $0.assign(SteamStorageAssignment(appID: 480, location: other, name: "Spacewar", installed: false)) } } != nil, "a game keeps the place it was first installed to")
check(catalog.assignments[480]?.location == location, "a refused change leaves the catalog as it was")
check(throwsError { _ = try SteamStorageLocation(libraryID: UUID().uuidString, relativePath: "../x") } != nil, "a location that leaves the library is refused")

var reloaded = try! SteamStorageCatalog.load(from: file)
check(reloaded == catalog, "the catalog survives a restart exactly")
try! reloaded.transaction(file: file) { $0.remove(appID: 480) }
check(try! SteamStorageCatalog.load(from: file).assignments.isEmpty, "a removed game stays removed after a restart")
try! Data("{ not json".utf8).write(to: file)
check(throwsError { _ = try SteamStorageCatalog.load(from: file) } != nil, "a damaged catalog is an error, not an empty catalog that would forget the games")
try? fm.removeItem(at: file)
check(try! SteamStorageCatalog.load(from: file).assignments.isEmpty, "no catalog file yet is simply empty")

// MARK: the drive mapping (dosdevices/e: and drive_c/MadeiraExternalLibrary)
let prefix = dir("Prefix"); let dos = dir("Prefix/dosdevices")
let link = dos.appendingPathComponent("e:")
try! SteamStorageMapping.replace(link, root: drive, libraryID: id, ownerID: nil)
check((try? fm.destinationOfSymbolicLink(atPath: link.path)) == drive.path, "the E: link points at the SSD folder")
try! SteamStorageMapping.replace(link, root: drive, libraryID: id, ownerID: id)
check((try? fm.destinationOfSymbolicLink(atPath: link.path)) == drive.path, "mapping again (the next session) keeps working")
let moved = dir("Moved"); try! Data(id.utf8).write(to: moved.appendingPathComponent(".madeira-library-id"))
try! SteamStorageMapping.replace(link, root: moved, libraryID: id, ownerID: id)
check((try? fm.destinationOfSymbolicLink(atPath: link.path)) == moved.path, "the same library at a new mount path is mapped again (the drive was plugged into another port)")
let foreign = dos.appendingPathComponent("f:")
try! fm.createSymbolicLink(at: foreign, withDestinationURL: outside)
check(throwsError { try SteamStorageMapping.replace(foreign, root: drive, libraryID: id, ownerID: UUID().uuidString) } != nil, "a link that belongs to something else is never replaced")
try! SteamStorageMapping.replace(foreign, root: drive, libraryID: id, ownerID: UUID().uuidString, claimsExistingSymlink: true)
check((try? fm.destinationOfSymbolicLink(atPath: foreign.path)) == drive.path, "in Porthole's own prefix a link left by an earlier registration is replaced")
let realFolder = dos.appendingPathComponent("g:"); try! fm.createDirectory(at: realFolder, withIntermediateDirectories: true)
check(throwsError { try SteamStorageMapping.replace(realFolder, root: drive, libraryID: id, ownerID: id) } != nil, "a real folder is never replaced by the link")
check(throwsError { try SteamStorageMapping.replace(realFolder, root: drive, libraryID: id, ownerID: id, claimsExistingSymlink: true) } != nil, "even then a real folder is never replaced")
check(throwsError { try SteamStorageMapping.replace(dos.appendingPathComponent("h:"), root: otherDrive, libraryID: id, ownerID: nil) } != nil, "a folder that is not the registered library is not mapped")
_ = prefix

// MARK: Steam's libraryfolders.vdf
let added = try! ExternalSteamLibraries.add(paths: ["MadeiraExternalLibrary"], to: nil)
let text = String(decoding: added, as: UTF8.self)
check(text.contains("C:\\\\MadeiraExternalLibrary"), "the SSD folder is listed as a Steam library")
let again = try! ExternalSteamLibraries.add(paths: ["MadeiraExternalLibrary", "Other"], to: added)
let againText = String(decoding: again, as: UTF8.self)
check(againText.components(separatedBy: "MadeiraExternalLibrary").count == 2 && againText.contains("Other"), "adding it again does not list it twice, and a new path is added")

// MARK: what the drive is formatted as
check(SteamStorageFileSystem.typeName(at: drive) != nil, "the file system's type name is readable")
check(!SteamStorageFileSystem.isFAT(at: drive), "the Mac's own disk is not taken for a FAT drive")

// MARK: the device's own storage is not an external drive
check(SteamStorageFileSystem.isDeviceStoragePath("/private/var/mobile/Containers/Shared/AppGroup/ABC/File Provider Storage/Documents"), "a folder in On My iPad is the device's own storage")
check(SteamStorageFileSystem.isDeviceStoragePath("/private/var/mobile/Containers/Data/Application/ABC/Documents/games"), "a folder inside an app container is the device's own storage")
check(!SteamStorageFileSystem.isDeviceStoragePath("/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/ABC/games"), "a folder on a mounted drive is not")
do {
    var catalog = SteamStorageCatalog()
    let lib = SteamStorageLibrary(id: UUID().uuidString, name: "Games", bookmark: Data([1]))
    try! catalog.register(lib)
    try! catalog.assign(SteamStorageAssignment(appID: 10, location: try! SteamStorageLocation(libraryID: lib.id, relativePath: "steamapps/common/A"), name: "A", installed: true))
    catalog.forgetExternal()
    check(catalog.external == nil && catalog.assignments.isEmpty, "forgetting the folder drops it and the games recorded on it")
    try! catalog.register(SteamStorageLibrary(id: UUID().uuidString, name: "Other", bookmark: Data([2])))
    check(catalog.external?.name == "Other", "another folder can be registered afterwards")
}

// MARK: free space

check((try? SteamStorageCapacity.resolve(important: 0, ordinary: 5_000, filesystem: 7_000)) == 7_000, "a volume that reports zero 'important' space but has room is not taken for full")
check((try? SteamStorageCapacity.resolve(important: nil, ordinary: nil, filesystem: nil)) == nil, "a failed space query is an error, never unlimited space")
check((try? SteamStorageCapacity.resolve(important: 0, ordinary: 0, filesystem: 0)) == 0, "a genuinely full drive is zero")
check((try? SteamStorageCapacity.availableBytes(at: drive)) ?? 0 > 0, "free space on a real folder is read")

try? fm.removeItem(at: base)
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
