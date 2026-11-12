import Foundation
var failed = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok:   \(name)" : "FAIL: \(name)"); if !ok { failed += 1 } }
let id = PrefixHealth.wicCLSID
let good = "WINE REGEDIT4\n\n[Software\\\\Classes\\\\CLSID\\\\{317D06E8-5F24-433D-BDF7-79CE68D8ABC2}] 1730000000\n@=\"WICImagingFactory2\"\n\n[Software\\\\Classes\\\\CLSID\\\\{317D06E8-5F24-433D-BDF7-79CE68D8ABC2}\\\\InprocServer32] 1730000000\n@=\"C:\\\\windows\\\\system32\\\\windowscodecs.dll\"\n\"ThreadingModel\"=\"Both\"\n\n[Software\\\\Other] 1\n@=\"x\"\n"
check("a registered server is found", PrefixHealth.inprocServer(clsid: id, in: good) == .registered("C:\\windows\\system32\\windowscodecs.dll"))
let bad = good.replacingOccurrences(of: "C:\\\\windows\\\\system32\\\\windowscodecs.dll", with: "\u{13}8\u{0c}9acs")
if case .unreadable = PrefixHealth.inprocServer(clsid: id, in: bad) { check("a garbled value is unreadable", true) } else { check("a garbled value is unreadable", false) }
check("no key is missing", PrefixHealth.inprocServer(clsid: id, in: "WINE REGEDIT4\n\n[Software\\\\Other] 1\n@=\"x\"\n") == .missing)
check("only the class id's own server counts", PrefixHealth.inprocServer(clsid: id, in: good.replacingOccurrences(of: "InprocServer32", with: "LocalServer32")) == .missing)
check("a bare dll name is fine", PrefixHealth.inprocServer(clsid: id, in: good.replacingOccurrences(of: "C:\\\\windows\\\\system32\\\\", with: "")) == .registered("windowscodecs.dll"))
// repair
let fixed = PrefixHealth.setInprocServer(clsid: id, to: PrefixHealth.wicPath, in: bad)
check("a garbled value is replaced", PrefixHealth.inprocServer(clsid: id, in: fixed) == .registered(PrefixHealth.wicPath))
check("the rest of the file is kept", fixed.contains("[Software\\\\Other] 1") && fixed.contains("\"ThreadingModel\"=\"Both\""))
let added = PrefixHealth.setInprocServer(clsid: id, to: PrefixHealth.wicPath, in: "WINE REGEDIT4\n\n[Software\\\\Other] 1\n@=\"x\"\n")
check("a missing key is added", PrefixHealth.inprocServer(clsid: id, in: added) == .registered(PrefixHealth.wicPath))
let idem = PrefixHealth.setInprocServer(clsid: id, to: PrefixHealth.wicPath, in: good)
check("a good value stays", idem == good.replacingOccurrences(of: "@=\"C:\\\\windows\\\\system32\\\\windowscodecs.dll\"", with: "@=\"C:\\\\windows\\\\system32\\\\windowscodecs.dll\""))
let u = PrefixHealth.unreadableServers(in: bad + "\n[Software\\\\Classes\\\\CLSID\\\\{11111111-2222-3333-4444-555555555555}\\\\LocalServer32] 1\n@=\"\"C:\\\\x.exe\" /Automation\"\n")
check("garbage is counted, programs are not", u.count == 1 && u.examples.first?.contains(id) == true)
// restoring from a template
let tmpl = "WINE REGEDIT4\n\n[Software\\\\Classes\\\\CLSID\\\\{11111111-2222-3333-4444-555555555555}\\\\InprocServer32] 1\n@=\"C:\\\\windows\\\\system32\\\\foo.dll\"\n\n" + good.dropFirst(15)
let broken = bad + "\n[Software\\\\Classes\\\\CLSID\\\\{11111111-2222-3333-4444-555555555555}\\\\InprocServer32] 9\n@=\"\u{13}8\u{0c}9acs\"\n\n[Software\\\\Classes\\\\CLSID\\\\{99999999-2222-3333-4444-555555555555}\\\\InprocServer32] 9\n@=\"\u{13}8\"\n"
let r = PrefixHealth.restoring(broken, from: tmpl)
check("garbage is restored from the template", r.fixed == 2 && PrefixHealth.unreadableServers(in: r.text).count == 1 && r.unknown.count == 1)
check("the restored file reads back", PrefixHealth.inprocServer(clsid: id, in: r.text) == .registered("C:\\windows\\system32\\windowscodecs.dll"))
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
