import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct InboxFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    var id: URL { url }

    var type: UTType? { UTType(filenameExtension: url.pathExtension) }

    var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .text) { return "doc.text" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}

/// Files sent to this device by dropping them onto the mirror on the other device.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var files: [InboxFile] = []
    @State private var previewURL: URL?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    ContentUnavailableView {
                        Label("No Files Yet", systemImage: "tray")
                    } description: {
                        Text("Drag photos or files onto the mirror on your other device, and they arrive here.")
                    }
                } else {
                    List {
                        ForEach(files) { file in
                            Button {
                                previewURL = file.url
                            } label: {
                                InboxRow(file: file)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    delete(file)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                ShareLink(item: file.url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    delete(file)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } preview: {
                                FileThumbnail(url: file.url, symbol: file.symbol, size: 260)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !files.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Delete all received files?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { clearAll() }
            }
            .quickLookPreview($previewURL, in: files.map(\.url))
        }
        .onAppear {
            reload()
            model.markInboxSeen()
        }
        .onChange(of: model.inboxVersion) { _, _ in
            reload()
            model.markInboxSeen()
        }
    }

    private func reload() {
        let folder = SharedStore.shared.inboxURL
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        files = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { return nil }
            return InboxFile(url: url, size: Int64(values?.fileSize ?? 0), date: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    private func delete(_ file: InboxFile) {
        try? FileManager.default.removeItem(at: file.url)
        withAnimation { files.removeAll { $0.id == file.id } }
    }

    private func clearAll() {
        for file in files { try? FileManager.default.removeItem(at: file.url) }
        withAnimation { files.removeAll() }
    }
}

private struct InboxRow: View {
    let file: InboxFile

    var body: some View {
        HStack(spacing: 14) {
            FileThumbnail(url: file.url, symbol: file.symbol, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.date.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share \(file.url.lastPathComponent)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct FileThumbnail: View {
    let url: URL
    let symbol: String
    var size: CGFloat = 48

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: displayScale,
                representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.uiImage
            }
        }
        .accessibilityHidden(true)
    }
}
