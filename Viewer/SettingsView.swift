import SwiftUI

/// Where double-clicked .note and .mark files open. PDFs and the Measure service always use Sumi's window.
enum OpenMode: String, CaseIterable {
    case sumi
    case preview

    static let defaultsKey = "openSupernoteFilesIn"

    static var current: OpenMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(OpenMode.init) ?? .sumi
    }
}

struct SettingsView: View {
    @AppStorage(OpenMode.defaultsKey) private var openMode: OpenMode = .sumi

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Open Supernote files in:", selection: $openMode) {
                Text("Sumi for Supernote: thumbnails, live reload, measuring").tag(OpenMode.sumi)
                Text("Preview: annotate, sign and print with Apple's tools").tag(OpenMode.preview)
            }
            .pickerStyle(.radioGroup)
            Text("Applies to .note and .pdf.mark files opened from Finder. PDFs and Measure in Sumi for Supernote always open in Sumi.")
                .foregroundStyle(.secondary)
            Text("Preview opens a generated copy. To keep your Preview annotations, use File → Export or Duplicate. If the notebook changes, the copy is regenerated, but a copy you saved changes to is never overwritten.")
                .foregroundStyle(.secondary)
            Text("For .mark files, keep the original PDF next to it (X.pdf.mark → X.pdf).")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize()
    }
}
