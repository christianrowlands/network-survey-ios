import Foundation

/// A buffered, append-only text file for the CSV formats.
final class CSVFile {
    enum Dialect {
        /// Apache Commons CSV `CSVFormat.DEFAULT` as the Android app uses it:
        /// CRLF, minimal quoting, `# ` header comments.
        case commonsCSV
    }

    let url: URL
    private let dialect: Dialect
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var bytesWritten: Int64 = 0

    /// Creates the file. Fails if it already exists.
    init(url: URL, dialect: Dialect) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.url = url
        self.dialect = dialect
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    private let lineEnd = "\r\n"

    func comment(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines { append("# " + line + lineEnd) }
    }

    func row(_ fields: [String]) {
        var line = ""
        for (index, field) in fields.enumerated() {
            if index > 0 { line.append(",") }
            line.append(encode(field, first: index == 0))
        }
        append(line + lineEnd)
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        try flush()
        try handle.close()
    }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        buffer.append(data)
        bytesWritten += Int64(data.count)
        if buffer.count >= 64 * 1024 { try? flush() }
    }

    private func encode(_ field: String, first: Bool) -> String {
        guard Self.commonsNeedsQuotes(field, first: first) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Commons CSV `QuoteMode.MINIMAL`: an empty first field, a field starting
    /// with a character up to `#`, one holding a delimiter, quote, CR or LF,
    /// or one ending with a character up to space.
    static func commonsNeedsQuotes(_ field: String, first: Bool) -> Bool {
        guard let head = field.unicodeScalars.first, let tail = field.unicodeScalars.last else { return first }
        if head.value <= 0x23 { return true }
        if field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) { return true }
        return tail.value <= 0x20
    }
}

/// File names in the Android app's style: `<prefix>yyyyMMdd-HHmmss.csv`, with
/// `-1`, `-2` added if the name is taken.
enum FileNaming {
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func uniqueURL(in directory: URL, prefix: String, session: SessionInfo, extension ext: String) -> URL {
        let stamp = timestamp(session.startedAt, timeZone: session.timeZone)
        var url = directory.appendingPathComponent("\(prefix)\(stamp).\(ext)")
        var counter = 0
        while FileManager.default.fileExists(atPath: url.path) {
            counter += 1
            url = directory.appendingPathComponent("\(prefix)\(stamp)-\(counter).\(ext)")
        }
        return url
    }
}
