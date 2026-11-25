import AppKit
import Carbon
import CryptoKit
import Foundation

/// The app that owned the pasteboard when the copy happened.
public struct ClipboardSource: Codable, Equatable, Sendable {
    public let bundleID: String?
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    public static func frontmostApplication(
        workspace: NSWorkspace = .shared
    ) -> ClipboardSource? {
        // An overlay panel, such as iTerm2's hotkey window, takes keyboard
        // focus without activating its app, so `frontmostApplication` still
        // names whatever sits behind it. The front window knows better.
        //
        // Shorty's own window counts: copying out of its search box came from
        // Shorty, not from whatever happens to sit behind the panel.
        if let pid = frontWindowOwnerPID(),
           let application = NSRunningApplication(processIdentifier: pid) {
            return ClipboardSource(
                bundleID: application.bundleIdentifier,
                name: application.localizedName
            )
        }

        guard let application = workspace.frontmostApplication else {
            return nil
        }

        return ClipboardSource(
            bundleID: application.bundleIdentifier,
            name: application.localizedName
        )
    }

    /// Owner of the frontmost ordinary window. Skips always-on-top HUDs by
    /// capping the window layer, and menu bar extras by requiring real size.
    static func frontWindowOwnerPID() -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return attributableOwnerPID(from: windows)
    }

    /// Split from the window query so the filtering can be tested without a
    /// window server.
    static func attributableOwnerPID(from windows: [[String: Any]]) -> pid_t? {
        for window in windows {
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= 0,
                  layer <= Self.maxAttributableWindowLayer,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width >= Self.minAttributableWindowSize.width,
                  frame.height >= Self.minAttributableWindowSize.height else {
                continue
            }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            guard !Self.systemWindowOwners.contains(ownerName) else {
                continue
            }

            return ownerPID
        }

        return nil
    }

    /// Normal windows are layer 0; iTerm2's hotkey window sits at 25. HUD
    /// overlays live far above that and never own a copy.
    private static let maxAttributableWindowLayer = 25
    private static let minAttributableWindowSize = CGSize(width: 200, height: 100)
    private static let systemWindowOwners: Set<String> = [
        "Window Server",
        "Control Center",
        "Notification Center",
        "Dock",
        "Spotlight",
    ]
}

public struct ClipboardItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var plainText: String
    /// What Vision read in `image`, once it has. A label and a search key,
    /// never what gets pasted.
    public var ocrText: String?
    public var rtfData: Data?
    public var rtfdData: Data?
    public var additionalRepresentations: [ClipboardRepresentation]
    public var createdAt: Date
    public var updatedAt: Date
    /// Absent for older entries and for text Shorty itself put on the pasteboard.
    public var source: ClipboardSource?
    /// Image bytes live in the asset store; this is the reference.
    public var image: ClipboardAsset?
    /// Files copied in Finder, kept as paths rather than copies.
    public var files: [ClipboardFileReference]

    public init(
        plainText: String,
        rtfData: Data? = nil,
        rtfdData: Data? = nil,
        additionalRepresentations: [ClipboardRepresentation] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: ClipboardSource? = nil,
        image: ClipboardAsset? = nil,
        files: [ClipboardFileReference] = [],
        ocrText: String? = nil
    ) {
        // `ocrText` is not part of the id: it is read out of the picture
        // after the entry exists, and an identity that changed when the
        // reading arrived would stop matching the row it was stored under.
        self.id = Self.makeID(
            plainText: plainText,
            rtfData: rtfData,
            rtfdData: rtfdData,
            additionalRepresentations: additionalRepresentations,
            image: image,
            files: files
        )
        self.plainText = plainText
        self.ocrText = ocrText
        self.rtfData = rtfData
        self.rtfdData = rtfdData
        self.additionalRepresentations = additionalRepresentations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.image = image
        self.files = files
    }

    /// Text the picker search matches against, including file paths.
    public var searchableText: [String] {
        var values = [plainText]

        if plainText.isEmpty, image != nil {
            values.append("image")

            if let ocrText {
                values.append(ocrText)
            }
        }

        values.append(contentsOf: files.map(\.name))
        values.append(contentsOf: files.map(\.path))

        return values.filter { !$0.isEmpty }
    }

    /// What the list and the detail pane show. Image-only copies carry no text.
    public var previewText: String {
        if !plainText.isEmpty {
            return plainText
        }

        if let image {
            // What the picture says, when it says anything; its size is all
            // there is to show otherwise.
            if let ocrText, !ocrText.isEmpty {
                return ocrText
            }

            return "Image \(image.pixelSizeLabel)"
        }

        if !files.isEmpty {
            return files.map(\.name).joined(separator: ", ")
        }

        return plainText
    }

    /// Types a copier uses to say "this is not for keeping".
    ///
    /// `ConcealedType` is what password managers and Keychain Access mark a
    /// copied secret with, and the rest are the conventions clipboard
    /// managers agreed on for text a person never typed. A history that keeps
    /// passwords is worse than no history.
    public static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    /// Whether the copier asked for this to be left alone.
    public static func isPrivate(types: [String]) -> Bool {
        types.contains { privateTypes.contains($0) }
    }

    public static func read(
        from pasteboard: NSPasteboard,
        now: Date = Date(),
        source: ClipboardSource? = nil,
        assetStore: ClipboardAssetStore? = nil
    ) -> ClipboardItem? {
        // Asked first: a secret should not be read off the pasteboard at all,
        // let alone written to disk.
        guard !isPrivate(types: pasteboard.types?.map(\.rawValue) ?? []) else {
            return nil
        }

        let rtfData = firstData(from: pasteboard, types: PasteboardTypes.rtf)
        let rtfdData = firstData(from: pasteboard, types: PasteboardTypes.rtfd)
        let additionalRepresentations = additionalRepresentations(from: pasteboard)
        let files = fileReferences(from: pasteboard)
        let plainText = firstString(from: pasteboard, types: PasteboardTypes.string)
            ?? plainText(fromRTFDData: rtfdData)
            ?? plainText(fromRTFData: rtfData)
            ?? ""

        // A copied file already describes itself by path; only inline image
        // data needs storing.
        let image = files.isEmpty ? storedImage(from: pasteboard, assetStore: assetStore) : nil

        guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            rtfData != nil ||
            rtfdData != nil ||
            !additionalRepresentations.isEmpty ||
            image != nil ||
            !files.isEmpty else {
            return nil
        }

        return ClipboardItem(
            plainText: plainText,
            rtfData: rtfData,
            rtfdData: rtfdData,
            additionalRepresentations: additionalRepresentations,
            createdAt: now,
            updatedAt: now,
            source: source,
            image: image,
            files: files
        )
    }

    private static func fileReferences(from pasteboard: NSPasteboard) -> [ClipboardFileReference] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }

        return urls.filter(\.isFileURL).map { ClipboardFileReference(path: $0.path) }
    }

    /// Prefers the pasteboard's own PNG. Screenshot TIFF is uncompressed and
    /// often many times larger, so it is re-encoded before storing.
    private static func storedImage(
        from pasteboard: NSPasteboard,
        assetStore: ClipboardAssetStore?
    ) -> ClipboardAsset? {
        guard let assetStore else {
            return nil
        }

        if let data = pasteboard.data(forType: .png),
           let representation = NSBitmapImageRep(data: data) {
            return assetStore.store(
                data: data,
                type: "public.png",
                pixelWidth: representation.pixelsWide,
                pixelHeight: representation.pixelsHigh
            )
        }

        guard let tiffData = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiffData),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            return nil
        }

        return assetStore.store(
            data: pngData,
            type: "public.png",
            pixelWidth: representation.pixelsWide,
            pixelHeight: representation.pixelsHigh
        )
    }

    public static func joinedTrimmedNonEmptyLines(from text: String) -> String {
        lineComponents(in: text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined()
    }

    public var joinedTrimmedNonEmptyLines: String {
        Self.joinedTrimmedNonEmptyLines(from: plainText)
    }

    public func menuTitle(maxLength: Int = ClipboardConstants.maxMenuItemTitleLength) -> String {
        let preview = linePreview()
        let title = preview.title
        let additionalLineCount = preview.additionalLineCount
        let suffix = additionalLineCount > 0 ? " +\(additionalLineCount)" : ""
        let contentMaxLength = max(1, maxLength - suffix.count)

        return title.shortyTruncated(maxLength: contentMaxLength) + suffix
    }

    public func pickerLinePreview(maxTitleLength: Int = ClipboardConstants.maxPickerItemTitleLength) -> ClipboardLinePreview {
        let preview = linePreview()
        return ClipboardLinePreview(
            title: preview.title.shortyTruncated(maxLength: maxTitleLength),
            additionalLineCount: preview.additionalLineCount
        )
    }

    private func linePreview() -> ClipboardLinePreview {
        let lines = Self.lineComponents(in: previewText)
        let titleLineIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? 0
        let title = lines.indices.contains(titleLineIndex) ? lines[titleLineIndex] : ""
        let additionalLineCount = max(0, lines.count - titleLineIndex - 1)

        return ClipboardLinePreview(title: title, additionalLineCount: additionalLineCount)
    }

    private static func lineComponents(in text: String) -> [String] {
        var lines: [String] = []
        var currentLine = String.UnicodeScalarView()
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            if scalar == "\r" {
                lines.append(String(currentLine))
                currentLine.removeAll(keepingCapacity: true)
                index = text.unicodeScalars.index(after: index)
                if index < text.unicodeScalars.endIndex, text.unicodeScalars[index] == "\n" {
                    index = text.unicodeScalars.index(after: index)
                }
                continue
            }

            if Self.isNonCarriageReturnNewline(scalar) {
                lines.append(String(currentLine))
                currentLine.removeAll(keepingCapacity: true)
            } else {
                currentLine.append(scalar)
            }

            index = text.unicodeScalars.index(after: index)
        }

        lines.append(String(currentLine))
        return lines
    }

    private static func isNonCarriageReturnNewline(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" ||
            scalar == "\u{000B}" ||
            scalar == "\u{000C}" ||
            scalar == "\u{0085}" ||
            scalar == "\u{2028}" ||
            scalar == "\u{2029}"
    }

    private static func firstString(from pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> String? {
        types.compactMap { pasteboard.string(forType: $0) }.first { !$0.isEmpty }
    }

    private static func firstData(from pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Data? {
        types.compactMap { pasteboard.data(forType: $0) }.first
    }

    private static func plainText(fromRTFData data: Data?) -> String? {
        guard let data, let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }

        return attributed.string
    }

    private static func plainText(fromRTFDData data: Data?) -> String? {
        guard let data, let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) else {
            return nil
        }

        return attributed.string
    }

    private static func additionalRepresentations(from pasteboard: NSPasteboard) -> [ClipboardRepresentation] {
        guard let item = pasteboard.pasteboardItems?.first else {
            return []
        }

        let builtInTypes = Set((PasteboardTypes.string + PasteboardTypes.rtf + PasteboardTypes.rtfd).map(\.rawValue))

        return item.types.compactMap { type in
            guard !builtInTypes.contains(type.rawValue),
                  shouldPreserveAdditionalType(type),
                  let data = item.data(forType: type),
                  !data.isEmpty else {
                return nil
            }

            return ClipboardRepresentation(type: type.rawValue, data: data)
        }
    }

    private static func shouldPreserveAdditionalType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let rawValue = type.rawValue.lowercased()

        if rawValue.contains("image") ||
            rawValue.contains("png") ||
            rawValue.contains("tiff") ||
            rawValue.contains("jpeg") ||
            rawValue.contains("pdf") ||
            rawValue.contains("file") ||
            rawValue.contains("url") ||
            rawValue.contains("sound") ||
            rawValue.contains("movie") ||
            rawValue.contains("video") ||
            rawValue.contains("promise") ||
            rawValue.contains("bookmark") {
            return false
        }

        return rawValue.contains("html") ||
            rawValue.contains("webarchive") ||
            rawValue.contains("web archive") ||
            rawValue.contains("attributed") ||
            rawValue.contains("rich") ||
            rawValue.hasPrefix("com.apple.notes")
    }

    private static func makeID(
        plainText: String,
        rtfData: Data?,
        rtfdData: Data?,
        additionalRepresentations: [ClipboardRepresentation],
        image: ClipboardAsset? = nil,
        files: [ClipboardFileReference] = []
    ) -> String {
        var data = Data()
        data.appendUTF8("plainText:")
        data.appendUTF8(plainText)

        if let rtfData {
            data.appendUTF8("\nrtf:")
            data.append(rtfData)
        }

        if let rtfdData {
            data.appendUTF8("\nrtfd:")
            data.append(rtfdData)
        }

        for representation in additionalRepresentations {
            data.appendUTF8("\nadditional:")
            data.appendUTF8(representation.type)
            data.appendUTF8(":")
            data.append(representation.data)
        }

        if let image {
            data.appendUTF8("\nimage:")
            data.appendUTF8(image.fileName)
        }

        for file in files {
            data.appendUTF8("\nfile:")
            data.appendUTF8(file.path)
        }

        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case plainText
        case rtfData
        case rtfdData
        case additionalRepresentations
        case createdAt
        case updatedAt
        case source
        case image
        case files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plainText = try container.decode(String.self, forKey: .plainText)
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        rtfdData = try container.decodeIfPresent(Data.self, forKey: .rtfdData)
        additionalRepresentations = try container.decodeIfPresent(
            [ClipboardRepresentation].self,
            forKey: .additionalRepresentations
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        source = try container.decodeIfPresent(ClipboardSource.self, forKey: .source)
        image = try container.decodeIfPresent(ClipboardAsset.self, forKey: .image)
        files = try container.decodeIfPresent([ClipboardFileReference].self, forKey: .files) ?? []
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Self.makeID(
            plainText: plainText,
            rtfData: rtfData,
            rtfdData: rtfdData,
            additionalRepresentations: additionalRepresentations,
            image: image,
            files: files
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(plainText, forKey: .plainText)
        try container.encodeIfPresent(rtfData, forKey: .rtfData)
        try container.encodeIfPresent(rtfdData, forKey: .rtfdData)
        if !additionalRepresentations.isEmpty {
            try container.encode(additionalRepresentations, forKey: .additionalRepresentations)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(image, forKey: .image)
        if !files.isEmpty {
            try container.encode(files, forKey: .files)
        }
    }
}

public struct ClipboardLinePreview: Equatable, Sendable {
    public let title: String
    public let additionalLineCount: Int

    public var trailingLineCountLabel: String? {
        additionalLineCount > 0 ? "+\(additionalLineCount)" : nil
    }
}

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public enum ClipboardConstants {
    /// A clipboard worth searching rather than a short undo stack: entries
    /// are a few hundred bytes of text each, so a thousand costs little and
    /// keeps a week of work within reach.
    public static let maxStoredItems = 1_000
    public static let maxVisibleItems = 1_000
    public static let maxMenuItemTitleLength = 60
    public static let maxPickerItemTitleLength = 240
    public static let pollInterval: TimeInterval = 0.75
    /// Bigger images are skipped rather than written to the asset store.
    public static let maxStoredImageBytes = 10 * 1024 * 1024
}

public final class ClipboardHistoryStore {
    /// Settable, since it comes from config that is read after the store is
    /// built and can change while Shorty runs.
    private var maxStoredItems: Int
    private let assetStore: ClipboardAssetStore
    private let history: ClipboardHistoryDatabase?
    /// Settable like the limit, since it comes from config read after the
    /// store is built.
    private var readsPictures: Bool

    public init(
        database: ShortyDatabase? = .shared,
        maxStoredItems: Int = ClipboardConstants.maxStoredItems,
        assetStore: ClipboardAssetStore? = nil,
        directory: URL? = nil,
        readsPictures: Bool = true
    ) {
        self.maxStoredItems = maxStoredItems
        self.readsPictures = readsPictures
        // Pictures live beside the database that references them. Left to a
        // fixed path, a store opened on a scratch database swept the real
        // directory, where nothing it could see was referenced: every image
        // in the history was deleted that way.
        let assetDirectory = database.map { $0.directory.appendingPathComponent("ClipboardAssets", isDirectory: true) }
        self.assetStore = assetStore
            ?? assetDirectory.map { ClipboardAssetStore(directory: $0) }
            ?? ClipboardAssetStore()
        history = database.map { ClipboardHistoryDatabase(database: $0) }

        if let database {
            StorageMigration.run(into: database, directory: directory)
        }

        // A crash or a hand-edited history can leave files behind.
        self.assetStore.removeOrphans(keeping: referencedAssets(), graceSeconds: 300)
    }

    /// A store of its own, rooted beside the given history file.
    ///
    /// The database lives next to where the JSON did, which is what lets a
    /// caller point the whole store at a directory of its own.
    public convenience init(
        url: URL,
        maxStoredItems: Int = ClipboardConstants.maxStoredItems,
        assetStore: ClipboardAssetStore = ClipboardAssetStore()
    ) {
        self.init(
            database: try? ShortyDatabase(
                url: url.deletingLastPathComponent().appendingPathComponent("Shorty.sqlite")
            ),
            maxStoredItems: maxStoredItems,
            assetStore: assetStore
        )
    }

    /// Where the history used to live, and where the database sits beside it.
    public static var defaultURL: URL {
        let applicationSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupportURL
            .appendingPathComponent("Shorty", isDirectory: true)
            .appendingPathComponent("ClipboardHistory.json")
    }

    /// Trims at once when the limit comes down, so a smaller number in the
    /// config takes effect rather than waiting for the next copy.
    /// Whether copied pictures are read, which the config can turn off.
    public func setReadsPictures(_ reads: Bool) {
        readsPictures = reads
    }

    public func setMaximumItems(_ limit: Int) {
        guard limit != maxStoredItems else {
            return
        }

        maxStoredItems = limit
        trim()
    }

    public func add(_ item: ClipboardItem) {
        guard let history else {
            return
        }

        var savedItem = item

        // A copy of something copied before keeps the date it first arrived,
        // and the app it came from when this time around nobody owned up.
        if let existing = try? history.existing(id: item.id) {
            savedItem.createdAt = existing.createdAt
            savedItem.source = savedItem.source ?? existing.source
        }

        savedItem.updatedAt = Date()

        try? history.write(savedItem)
        trim()

        readPicture(of: savedItem)
    }

    /// Reads the pictures already in the history that nothing has been read
    /// out of: everything copied before this existed, and anything a crash
    /// or a `read-images: off` spell left unread.
    public func readPicturesAlreadyStored(limit: Int = 200) {
        guard readsPictures, let history else {
            return
        }

        let assetStore = assetStore

        Self.recognitionQueue.async {
            guard let pending = try? history.itemsAwaitingText(limit: limit) else {
                return
            }

            for entry in pending {
                guard let data = assetStore.data(forFileName: entry.fileName) else {
                    continue
                }

                // Nothing legible is still an answer: stored empty, so the
                // picture is not read again on every launch.
                let text = ClipboardTextRecognition.text(in: data) ?? ""
                try? history.setOCRText(text, for: entry.id)
            }
        }
    }

    /// Reads the words in a copied picture, after the entry is stored.
    ///
    /// Off the copy path on purpose: recognition takes a few hundred
    /// milliseconds, and the pasteboard poll runs where a stall shows. The
    /// entry is already in the history by the time this starts, and gains
    /// its text whenever that finishes.
    private func readPicture(of item: ClipboardItem) {
        guard readsPictures, let image = item.image, item.ocrText == nil else {
            return
        }

        let assetStore = assetStore
        let history = history

        Self.recognitionQueue.async {
            guard let data = assetStore.data(for: image),
                  let text = ClipboardTextRecognition.text(in: data) else {
                return
            }

            try? history?.setOCRText(text, for: item.id)
        }
    }

    /// One picture at a time: recognition is CPU-heavy, and a burst of
    /// copies should not take the machine.
    private static let recognitionQueue = DispatchQueue(
        label: "com.shorty.clipboard.recognition",
        qos: .utility
    )

    /// Forgets one entry, and the image it pointed at when nothing else uses
    /// it. Returns false when the entry had already gone.
    @discardableResult
    public func remove(id: String) -> Bool {
        guard let history, (try? history.remove(id: id)) == true else {
            return false
        }

        assetStore.removeOrphans(keeping: referencedAssets())

        return true
    }

    public func addPlainText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        add(ClipboardItem(plainText: text))
    }

    @discardableResult
    public func addJoinedTrimmedNonEmptyLines(from item: ClipboardItem) -> String {
        let text = item.joinedTrimmedNonEmptyLines
        add(ClipboardItem(plainText: text))
        return text
    }

    public func recentItems(limit: Int = ClipboardConstants.maxVisibleItems) -> [ClipboardItem] {
        (try? history?.recentItems(limit: limit)) ?? []
    }

    private func trim() {
        guard let history, (try? history.trim(to: maxStoredItems)) == true else {
            return
        }

        assetStore.removeOrphans(keeping: referencedAssets())
    }

    private func referencedAssets() -> [ClipboardAsset] {
        (try? history?.referencedAssets()) ?? []
    }
}

public final class ClipboardMonitor: NSObject {
    private let pasteboard: NSPasteboard
    private let store: ClipboardHistoryStore
    private let assetStore: ClipboardAssetStore
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var cachedChangeCount: Int
    /// Told about every copy as it lands, so the app can get a head start on
    /// whatever the item needs looked up.
    public var didCapture: ((ClipboardItem) -> Void)?

    public init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        pollInterval: TimeInterval = ClipboardConstants.pollInterval,
        assetStore: ClipboardAssetStore = ClipboardAssetStore()
    ) {
        self.store = store
        self.assetStore = assetStore
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.cachedChangeCount = pasteboard.changeCount
        super.init()
    }

    public func start() {
        stop()
        cachedChangeCount = pasteboard.changeCount

        timer = Timer.scheduledTimer(
            timeInterval: pollInterval,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: true
        )

        timer?.tolerance = pollInterval / 3
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func notePasteboardChangeHandled() {
        cachedChangeCount = pasteboard.changeCount
    }

    @objc
    private func timerDidFire() {
        poll()
    }

    private func poll() {
        guard pasteboard.changeCount != cachedChangeCount else {
            return
        }

        cachedChangeCount = pasteboard.changeCount

        guard let item = ClipboardItem.read(
            from: pasteboard,
            source: .frontmostApplication(),
            assetStore: assetStore
        ) else {
            return
        }

        store.add(item)
        didCapture?(item)
    }
}

public final class ClipboardPaster {
    private let pasteboard: NSPasteboard
    private weak var monitor: ClipboardMonitor?
    private let assetStore: ClipboardAssetStore

    public init(
        pasteboard: NSPasteboard = .general,
        monitor: ClipboardMonitor? = nil,
        assetStore: ClipboardAssetStore = ClipboardAssetStore()
    ) {
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.assetStore = assetStore
    }

    public func paste(_ item: ClipboardItem) {
        copyToPasteboard(item)
        sendPasteCommand()
    }

    public func pasteText(_ text: String) {
        copyTextToPasteboard(text)
        sendPasteCommand()
    }

    public func copyToPasteboard(_ item: ClipboardItem) {
        // Files go back as URLs so Finder pastes the real file, and apps that
        // want bytes read them from the URL themselves.
        if !item.files.isEmpty {
            let urls = item.files.filter(\.exists).map(\.url)

            if !urls.isEmpty {
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
                monitor?.notePasteboardChangeHandled()
                return
            }
        }

        // Image data, not a file URL: a URL pastes as a path in text fields.
        if let asset = item.image, let data = assetStore.data(for: asset) {
            let type = NSPasteboard.PasteboardType(asset.type)
            pasteboard.declareTypes([type], owner: nil)
            pasteboard.setData(data, forType: type)
            monitor?.notePasteboardChangeHandled()
            return
        }

        var types: [NSPasteboard.PasteboardType] = []

        appendUnique(
            item.additionalRepresentations.map { NSPasteboard.PasteboardType($0.type) },
            to: &types
        )

        if item.rtfdData != nil {
            appendUnique(PasteboardTypes.rtfd, to: &types)
        }

        if item.rtfData != nil {
            appendUnique(PasteboardTypes.rtf, to: &types)
        }

        appendUnique(PasteboardTypes.string, to: &types)

        pasteboard.declareTypes(types, owner: nil)

        for representation in item.additionalRepresentations {
            pasteboard.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
        }

        if let rtfdData = item.rtfdData {
            PasteboardTypes.rtfd.forEach { pasteboard.setData(rtfdData, forType: $0) }
        }

        if let rtfData = item.rtfData {
            PasteboardTypes.rtf.forEach { pasteboard.setData(rtfData, forType: $0) }
        }

        PasteboardTypes.string.forEach { pasteboard.setString(item.plainText, forType: $0) }
        monitor?.notePasteboardChangeHandled()
    }

    public func copyTextToPasteboard(_ text: String) {
        pasteboard.declareTypes(PasteboardTypes.string, owner: nil)
        PasteboardTypes.string.forEach { pasteboard.setString(text, forType: $0) }
        monitor?.notePasteboardChangeHandled()
    }

    private func sendPasteCommand() {
        guard WindowActivator.requestAccessibilityIfNeeded() else {
            return
        }

        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval
            )

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
            keyDown?.flags = .maskCommand

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
            keyUp?.flags = .maskCommand

            keyDown?.post(tap: .cgAnnotatedSessionEventTap)
            keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func appendUnique(
        _ newTypes: [NSPasteboard.PasteboardType],
        to types: inout [NSPasteboard.PasteboardType]
    ) {
        for type in newTypes where !types.contains(type) {
            types.append(type)
        }
    }
}

private enum PasteboardTypes {
    static let string: [NSPasteboard.PasteboardType] = [.string, .deprecatedString]
    static let rtf: [NSPasteboard.PasteboardType] = [.rtf, .deprecatedRTF]
    static let rtfd: [NSPasteboard.PasteboardType] = [.rtfd, .deprecatedRTFD]
}

private extension NSPasteboard.PasteboardType {
    static var deprecatedString: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(rawValue: "NSStringPboardType")
    }

    static var deprecatedRTF: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(rawValue: "NSRTFPboardType")
    }

    static var deprecatedRTFD: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(rawValue: "NSRTFDPboardType")
    }
}

extension String {
    func shortyTruncated(maxLength: Int, symbol: String = "...") -> String {
        guard maxLength > symbol.count, count > maxLength else {
            return self
        }

        let endIndex = index(startIndex, offsetBy: maxLength - symbol.count)
        return String(self[..<endIndex]) + symbol
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
