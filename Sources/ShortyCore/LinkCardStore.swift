import CryptoKit
import Foundation

/// A card read from a page once and kept, so the same link does not send the
/// app back to the site on every launch.
public struct LinkCardRecord: Codable, Equatable, Sendable {
    public let title: String?
    public let summary: String?
    public let siteName: String?
    public let imageFileName: String?
    public let fetchedAt: Date
    /// The site said nothing, or could not be reached. Remembered so a dead
    /// link is not retried on every keypress, but for far less time.
    public let failed: Bool

    public init(
        title: String? = nil,
        summary: String? = nil,
        siteName: String? = nil,
        imageFileName: String? = nil,
        fetchedAt: Date,
        failed: Bool = false
    ) {
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageFileName = imageFileName
        self.fetchedAt = fetchedAt
        self.failed = failed
    }

    public func card(for url: URL) -> LinkCard {
        LinkCard(url: url, title: title, summary: summary, siteName: siteName)
    }

    func isFresh(at date: Date, successLife: TimeInterval, failureLife: TimeInterval) -> Bool {
        date.timeIntervalSince(fetchedAt) < (failed ? failureLife : successLife)
    }
}

/// Cards on disk, beside the history they belong to: the index in one JSON
/// file, each picture in its own file so the index stays small to read.
public final class LinkCardStore {
    /// A page can change what it says about itself, so a card is worth
    /// keeping for a week, no longer.
    public static let successLife: TimeInterval = 7 * 24 * 60 * 60
    /// A site that was down deserves another chance the next day.
    public static let failureLife: TimeInterval = 24 * 60 * 60
    /// Enough for any history worth searching, and a bound on the disk.
    public static let maximumRecords = 400

    private let directory: URL
    private let fileManager: FileManager
    private var records: [String: LinkCardRecord]
    private var loaded = false

    public init(directory: URL = LinkCardStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        records = [:]
    }

    public static var defaultDirectory: URL {
        ClipboardHistoryStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("LinkCards", isDirectory: true)
    }

    private var indexURL: URL {
        directory.appendingPathComponent("Index.json")
    }

    /// What is known about a link, or nothing when it was never read or has
    /// gone stale.
    public func record(for url: URL, now: Date = Date()) -> LinkCardRecord? {
        load()

        guard let record = records[key(for: url)],
              record.isFresh(at: now, successLife: Self.successLife, failureLife: Self.failureLife) else {
            return nil
        }

        return record
    }

    public func imageData(for record: LinkCardRecord) -> Data? {
        record.imageFileName
            .map { directory.appendingPathComponent($0) }
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// Remembers a card, or that the link had nothing to give. The picture is
    /// content addressed, so a site using one image across its pages costs a
    /// single file.
    @discardableResult
    public func save(
        _ card: LinkCard?,
        imageData: Data?,
        for url: URL,
        now: Date = Date()
    ) -> LinkCardRecord {
        load()

        let fileName = card == nil ? nil : imageData.flatMap(write(image:))
        let record = LinkCardRecord(
            title: card?.title,
            summary: card?.summary,
            siteName: card?.siteName,
            imageFileName: fileName,
            fetchedAt: now,
            failed: card == nil
        )

        records[key(for: url)] = record
        prune(now: now)
        writeIndex()

        return record
    }

    private func write(image data: Data) -> String? {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileName = "\(digest).img"
        let fileURL = directory.appendingPathComponent(fileName)

        guard !fileManager.fileExists(atPath: fileURL.path) else {
            return fileName
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return nil
        }

        return fileName
    }

    /// Drops what has gone stale, then the oldest of what is left, then any
    /// picture nothing points at any more.
    private func prune(now: Date) {
        records = records.filter {
            $0.value.isFresh(at: now, successLife: Self.successLife, failureLife: Self.failureLife)
        }

        if records.count > Self.maximumRecords {
            let keep = records
                .sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(Self.maximumRecords)

            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        removeOrphanedImages()
    }

    private func removeOrphanedImages() {
        let referenced = Set(records.values.compactMap(\.imageFileName))
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []

        for file in files where file.hasSuffix(".img") && !referenced.contains(file) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private func load() {
        guard !loaded else {
            return
        }

        loaded = true

        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder.linkCards.decode([String: LinkCardRecord].self, from: data) else {
            return
        }

        records = stored
    }

    private func writeIndex() {
        guard let data = try? JSONEncoder.linkCards.encode(records) else {
            return
        }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: [.atomic])
    }

    /// Addresses differing only by fragment are the same page to a reader.
    private func key(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil

        return components?.url?.absoluteString ?? url.absoluteString
    }
}

private extension JSONEncoder {
    static var linkCards: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var linkCards: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
