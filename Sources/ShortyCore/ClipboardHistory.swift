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
        workspace: NSWorkspace = .shared,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> ClipboardSource? {
        guard let application = workspace.frontmostApplication,
              application.processIdentifier != ownPID else {
            return nil
        }

        return ClipboardSource(
            bundleID: application.bundleIdentifier,
            name: application.localizedName
        )
    }
}

public struct ClipboardItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var plainText: String
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
        files: [ClipboardFileReference] = []
    ) {
        self.id = Self.makeID(
            plainText: plainText,
            rtfData: rtfData,
            rtfdData: rtfdData,
            additionalRepresentations: additionalRepresentations,
            image: image,
            files: files
        )
        self.plainText = plainText
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
            return "Image \(image.pixelSizeLabel)"
        }

        if !files.isEmpty {
            return files.map(\.name).joined(separator: ", ")
        }

        return plainText
    }

    public static func read(
        from pasteboard: NSPasteboard,
        now: Date = Date(),
        source: ClipboardSource? = nil,
        assetStore: ClipboardAssetStore? = nil
    ) -> ClipboardItem? {
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

    func pickerLinePreview(maxTitleLength: Int = ClipboardConstants.maxPickerItemTitleLength) -> ClipboardLinePreview {
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

struct ClipboardLinePreview: Equatable, Sendable {
    let title: String
    let additionalLineCount: Int

    var trailingLineCountLabel: String? {
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
    public static let maxStoredItems = 200
    public static let maxVisibleItems = 200
    public static let maxDirectMenuItems = 20
    public static let overflowSubmenuSize = 20
    public static let maxOverflowSubmenus = 9
    public static let maxMenuItemTitleLength = 60
    public static let maxPickerItemTitleLength = 240
    public static let maxTooltipLength = 500
    public static let pollInterval: TimeInterval = 0.75
    /// Bigger images are skipped rather than written to the asset store.
    public static let maxStoredImageBytes = 10 * 1024 * 1024
}

public final class ClipboardHistoryStore {
    private let url: URL
    private let maxStoredItems: Int
    private let lock = NSRecursiveLock()
    private let assetStore: ClipboardAssetStore
    private var items: [ClipboardItem]

    public init(
        url: URL = ClipboardHistoryStore.defaultURL,
        maxStoredItems: Int = ClipboardConstants.maxStoredItems,
        assetStore: ClipboardAssetStore = ClipboardAssetStore()
    ) {
        self.url = url
        self.maxStoredItems = maxStoredItems
        self.assetStore = assetStore
        self.items = Self.loadItems(from: url)
        // A crash or a hand-edited history file can leave files behind.
        assetStore.removeOrphans(keeping: self.items.compactMap(\.image), graceSeconds: 300)
    }

    public static var defaultURL: URL {
        let applicationSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupportURL
            .appendingPathComponent("Shorty", isDirectory: true)
            .appendingPathComponent("ClipboardHistory.json")
    }

    public func add(_ item: ClipboardItem) {
        lock.lock()
        defer { lock.unlock() }

        var savedItem = item
        if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
            savedItem.createdAt = items[existingIndex].createdAt
            savedItem.source = savedItem.source ?? items[existingIndex].source
            items.remove(at: existingIndex)
        }

        savedItem.updatedAt = Date()
        items.insert(savedItem, at: 0)

        if items.count > maxStoredItems {
            items.removeSubrange(maxStoredItems..<items.count)
            assetStore.removeOrphans(keeping: items.compactMap(\.image))
        }

        save()
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
        lock.lock()
        defer { lock.unlock() }

        return Array(items.prefix(limit))
    }

    private static func loadItems(from url: URL) -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        return (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Clipboard history is best effort; runtime paste behavior should keep working.
        }
    }
}

public final class ClipboardMonitor: NSObject {
    private let pasteboard: NSPasteboard
    private let store: ClipboardHistoryStore
    private let assetStore: ClipboardAssetStore
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var cachedChangeCount: Int

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

private extension String {
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
