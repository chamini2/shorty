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
    private let cards: LinkCardDatabase?

    public init(
        database: ShortyDatabase? = .shared,
        directory: URL = LinkCardStore.defaultDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
        cards = database.map { LinkCardDatabase(database: $0) }
    }

    /// A store of its own, keeping both its database and its pictures in the
    /// given directory.
    public convenience init(directory: URL) {
        self.init(
            database: try? ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite")),
            directory: directory
        )
    }

    public static var defaultDirectory: URL {
        ClipboardHistoryStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("LinkCards", isDirectory: true)
    }

    /// What is known about a link, or nothing when it was never read or has
    /// gone stale.
    public func record(for url: URL, now: Date = Date()) -> LinkCardRecord? {
        guard let record = try? cards?.record(for: key(for: url)),
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
        let fileName = card == nil ? nil : imageData.flatMap(write(image:))
        let record = LinkCardRecord(
            title: card?.title,
            summary: card?.summary,
            siteName: card?.siteName,
            imageFileName: fileName,
            fetchedAt: now,
            failed: card == nil
        )

        try? cards?.write(record, for: key(for: url))
        prune(now: now)

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
        guard let referenced = try? cards?.prune(
            now: now,
            successLife: Self.successLife,
            failureLife: Self.failureLife,
            limit: Self.maximumRecords
        ) else {
            return
        }

        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []

        for file in files where file.hasSuffix(".img") && !referenced.contains(file) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Addresses differing only by fragment are the same page to a reader.
    private func key(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil

        return components?.url?.absoluteString ?? url.absoluteString
    }
}
