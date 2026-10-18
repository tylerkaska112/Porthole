// Reproduces how AddGameFlow hands a picked folder to the import sheet, with the app's real FolderPickerSheet (UI/FilePickerSheet.swift), on the iOS simulator.
import SwiftUI

@main struct ImportPickerHarness: App {
    var body: some Scene { WindowGroup { Root() } }
}

struct Root: View {
    @State private var showAdd = false
    var body: some View {
        VStack { Button("Open Add a game") { showAdd = true }.font(.title2) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showAdd) { AddStub() }
    }
}

private struct ImportTarget: Identifiable { let url: URL; var id: URL { url } }

/// The same structure as AddGameFlow: two sheets on one view, set in the same moment by the picker's callback.
struct AddStub: View {
    @State private var pickFolder = false
    @State private var importing: URL?
    @State private var log: [String] = []
    var body: some View {
        VStack(spacing: 20) {
            Button("Import a game folder") { pickFolder = true }.font(.title2)
            ForEach(log, id: \.self) { Text($0).font(.footnote) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $pickFolder) {
            FolderPickerSheet(onPick: { url in log.append("picked \(url.lastPathComponent)"); pickFolder = false; importing = url },
                              onCancel: { log.append("cancelled"); pickFolder = false })
        }
        .sheet(item: Binding(get: { importing.map(ImportTarget.init) }, set: { if $0 == nil { importing = nil } })) { target in
            VStack { Text("IMPORT SHEET SHOWN").font(.largeTitle); Text(target.url.lastPathComponent) }.interactiveDismissDisabled()
        }
    }
}
