import Foundation
import NSMessaging

/// File logging in the NS CSV formats: one file per record type per session,
/// created when the first record of that type arrives (as the Android app
/// does), in the session folder.
public actor NSCSVDestination: Destination {
    public nonisolated let kind = DestinationKind.nsCSV

    private var session: SessionInfo?
    private var files: [NSCSVFormat: CSVFile] = [:]
    private var closedFiles: [DestinationSnapshot.File] = []
    private var recordsAccepted = 0
    private var lastError: String?

    public init() {}

    public func start(_ session: SessionInfo) async throws {
        try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
        self.session = session
        files = [:]
        closedFiles = []
        recordsAccepted = 0
        lastError = nil
    }

    public func accept(_ records: [SurveyRecord]) async {
        guard session != nil else { return }
        for record in records {
            switch record.kind {
            case .ap(let ns, _): write(.wifi, NSCSVRow.wifi(ns.data))
            case .ble(let ns, _): write(.bluetooth, NSCSVRow.bluetooth(ns.data))
            case .client(let ns, _): write(.client, NSCSVRow.client(ns.data, boardID: record.boardID))
            case .probe(let ns, let probe): write(.probe, NSCSVRow.probe(ns.data, probe, boardID: record.boardID))
            case .deviceStatus, .rawFrame: break
            }
        }
        for file in files.values {
            do { try file.flush() } catch { lastError = error.localizedDescription }
        }
    }

    public func stop() async {
        for file in files.values {
            do { try file.close() } catch { lastError = error.localizedDescription }
            closedFiles.append(.init(url: file.url, bytes: file.bytesWritten))
        }
        files = [:]
        session = nil
    }

    public func snapshot() async -> DestinationSnapshot {
        var snapshot = DestinationSnapshot(status: lastError.map { .error($0) } ?? (session == nil ? .off : .running))
        snapshot.recordsAccepted = recordsAccepted
        snapshot.lastError = lastError
        snapshot.files = (closedFiles + files.values.map { .init(url: $0.url, bytes: $0.bytesWritten) })
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return snapshot
    }

    private func write(_ format: NSCSVFormat, _ row: [String]) {
        guard let file = file(for: format) else { return }
        file.row(row)
        recordsAccepted += 1
    }

    private func file(for format: NSCSVFormat) -> CSVFile? {
        if let file = files[format] { return file }
        guard let session else { return nil }
        let url = FileNaming.uniqueURL(in: session.directory, prefix: format.filePrefix, session: session, extension: "csv")
        do {
            let file = try CSVFile(url: url, dialect: .commonsCSV)
            file.comment("Created by Network Survey iOS version=\(session.appVersion)")
            file.comment("CSV Version=\(format.version)")
            file.row(format.headers)
            files[format] = file
            return file
        } catch {
            lastError = "Could not create \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }
}
