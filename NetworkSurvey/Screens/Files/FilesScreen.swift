import QuickLook
import SurveyCore
import SwiftUI

/// Each survey's files, with share, preview, delete and a jump to the Files app.
struct FilesScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(SurveyData.self) private var data
    @Environment(\.openURL) private var openURL
    @State private var folders: [SurveyFolder] = []
    @State private var loaded = false
    @State private var preview: URL?
    @State private var pendingDelete: SurveyFolder?
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            List {
                Group {
                    ForEach(folders) { folder in
                        FolderSection(folder: folder, preview: $preview) {
                            pendingDelete = folder
                        }
                    }
                }
                .panelRows()
            }
            .themedList()
            .listStyle(.insetGrouped)
            .overlay {
                if loaded && folders.isEmpty {
                    ContentUnavailableView(
                        "No survey files yet",
                        systemImage: "folder",
                        description: Text("Each survey's files are kept here and in the Files app under On My iPhone > Network Survey.")
                    )
                }
            }
            .accessibilityIdentifier("files.list")
            .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openInFilesApp()
                    } label: {
                        Label("Open in Files", systemImage: "folder.badge.gearshape")
                    }
                    .accessibilityIdentifier("files.openInFiles")
                }
            }
            .refreshable { await reload() }
            .quickLookPreview($preview)
            .confirmationDialog(
                "Delete this survey?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { folder in
                Button("Delete files and survey data", role: .destructive) { delete(folder) }
            } message: { folder in
                Text("Deletes \(folder.files.count) files (\(DataFormat.bytes(folder.totalBytes))) and removes the survey from the Map and Lists. This cannot be undone.")
            }
            .alert("Could not delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK") {}
            } message: {
                Text(deleteError ?? "")
            }
            .task(id: data.sessions.map(\.id)) {
                // Sizes grow while a survey records, so refresh every few seconds while visible.
                while !Task.isCancelled {
                    await reload()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    /// Where survey folders live (the app's Documents folder).
    private var root: URL { app.filesRoot }

    /// Scans the survey folders off the main actor.
    private func reload() async {
        let root = root
        let sessions = data.sessions
        let scanned = await Task.detached(priority: .utility) {
            SurveyFiles.folders(root: root, sessions: sessions)
        }.value
        folders = scanned
        loaded = true
    }

    /// Removes the files first; the survey's data goes only once they are gone.
    private func delete(_ folder: SurveyFolder) {
        let store = data.store
        Task {
            do {
                try await Task.detached { try SurveyFiles.delete(folder) }.value
                if let session = folder.session {
                    try await store.deleteSession(session.id)
                }
            } catch {
                deleteError = error.localizedDescription
            }
            await reload()
        }
    }

    /// The Files app opens at this app's folder with the shareddocuments scheme.
    private func openInFilesApp() {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = root.path
        if let url = components.url { openURL(url) }
    }
}

private struct FolderSection: View {
    let folder: SurveyFolder
    @Binding var preview: URL?
    let onDelete: () -> Void

    var body: some View {
        Section {
            ForEach(folder.files) { file in
                Button {
                    preview = file.url
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: file.name.hasSuffix(".pcapng") ? "waveform.path.ecg" : "tablecells")
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(file.kindName)
                                .foregroundStyle(Theme.Colors.ink)
                            Text(file.name)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.ink2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(DataFormat.bytes(file.bytes))
                            .font(Theme.Fonts.counter)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                }
                .contextMenu {
                    ShareLink(item: file.url)
                    Button { preview = file.url } label: { Label("Preview", systemImage: "eye") }
                }
                .accessibilityHint("Shows a preview")
            }
            if folder.files.isEmpty {
                Text("No files in this survey.")
                    .foregroundStyle(Theme.Colors.ink2)
            }
        } header: {
            header
        } footer: {
            if let session = folder.session {
                Text(session.missionId)
                    .font(Theme.Fonts.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(folder.date.map(DataFormat.dateTime) ?? folder.name)
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .textCase(nil)
                Text(summary)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .textCase(nil)
            }
            Spacer()
            if folder.isRecording {
                TagPill(text: "Recording", color: Theme.Colors.red)
                    .textCase(nil)
            } else {
                Menu {
                    ShareLink(items: folder.files.map(\.url)) {
                        Label("Share all files", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete survey", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: Theme.Spacing.touchTarget, minHeight: Theme.Spacing.touchTarget)
                }
                .accessibilityLabel("Survey actions")
                .accessibilityIdentifier("files.folderActions")
            }
        }
    }

    private var summary: String {
        let count = folder.files.count
        return "\(count) \(count == 1 ? "file" : "files"), \(DataFormat.bytes(folder.totalBytes))"
    }
}
