import Foundation
import SurveyCore

/// One survey's folder of files, matched to its stored session when there is one.
nonisolated struct SurveyFolder: Identifiable, Equatable, Sendable {
    var url: URL
    var name: String
    var date: Date?
    var files: [SurveyFile]
    var session: SessionRow?

    var id: String { name }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var isRecording: Bool { session != nil && session?.stoppedAt == nil }
}

nonisolated struct SurveyFile: Identifiable, Equatable, Sendable {
    var url: URL
    var bytes: Int64
    var modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// "Wi-Fi CSV", "Packet capture" from the file name. "WiGLE CSV" names files
    /// from older surveys; the app no longer writes them.
    var kindName: String {
        let lower = name.lowercased()
        if lower.hasSuffix(".pcapng") { return "Packet capture" }
        if lower.contains("-wigle-") { return "WiGLE CSV" }
        if lower.contains("-wifi-client-") { return "Wi-Fi clients CSV" }
        if lower.contains("-wifi-probe-") { return "Probe requests CSV" }
        if lower.contains("-bluetooth-") { return "Bluetooth CSV" }
        if lower.contains("-wifi-") { return "Wi-Fi CSV" }
        return url.pathExtension.uppercased()
    }
}

/// Reads and deletes the survey folders under `<root>/Surveys`.
nonisolated enum SurveyFiles {
    static func surveysDirectory(root: URL) -> URL {
        root.appendingPathComponent("Surveys", isDirectory: true)
    }

    /// Newest first. Folders are named by session start time (yyyyMMdd-HHmmss).
    static func folders(root: URL, sessions: [SessionRow], timeZone: TimeZone = .current) -> [SurveyFolder] {
        let manager = FileManager.default
        let directory = surveysDirectory(root: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else { return [] }
        let sessionsByFolder = Dictionary(
            sessions.map { (MissionID.timestamp($0.startedAt, timeZone: timeZone), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyyMMdd-HHmmss"
        return entries.compactMap { entry -> SurveyFolder? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let files = ((try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles])) ?? [])
                .compactMap { file -> SurveyFile? in
                    guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { return nil }
                    return SurveyFile(url: file, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
                }
                .sorted { $0.name < $1.name }
            let name = entry.lastPathComponent
            let session = sessionsByFolder[name]
            return SurveyFolder(url: entry, name: name, date: session?.startedAt ?? parser.date(from: name),
                                files: files, session: session)
        }
        .sorted { ($0.date ?? .distantPast, $0.name) > ($1.date ?? .distantPast, $1.name) }
    }

    static func delete(_ folder: SurveyFolder) throws {
        try FileManager.default.removeItem(at: folder.url)
    }
}
