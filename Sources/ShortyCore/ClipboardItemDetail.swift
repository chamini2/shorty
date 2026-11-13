import Foundation

/// What a picker entry holds, as shown in the detail pane next to the list.
public enum ClipboardItemKind: String, Equatable, Sendable {
    case text = "Text"
    case link = "Link"
    case richText = "Rich Text"
    case image = "Image"
    case snippet = "Snippet"
    case folder = "Folder"
    case file = "File"
}

public struct ClipboardDetailRow: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct ClipboardItemDetail: Equatable, Sendable {
    public let body: String
    public let kind: ClipboardItemKind
    /// Bundle ID of the app the text came from, for the row icon.
    public let sourceBundleID: String?
    /// Set when the pane should show a picture instead of text.
    public let image: ClipboardAsset?
    /// Set when the pane should show copied files instead of text.
    public let files: [ClipboardFileReference]
    public let rows: [ClipboardDetailRow]

    public init(
        body: String,
        kind: ClipboardItemKind,
        sourceBundleID: String? = nil,
        image: ClipboardAsset? = nil,
        files: [ClipboardFileReference] = [],
        rows: [ClipboardDetailRow]
    ) {
        self.body = body
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.image = image
        self.files = files
        self.rows = rows
    }
}

public enum ClipboardItemDetailBuilder {
    public static func detail(
        for entry: ClipboardPickerEntry,
        dateFormatter: DateFormatter = defaultDateFormatter()
    ) -> ClipboardItemDetail? {
        switch entry {
        case let .history(item):
            return detail(for: item, dateFormatter: dateFormatter)

        case let .snippet(groupTitle, snippet):
            return ClipboardItemDetail(
                body: snippet.content,
                kind: .snippet,
                rows: [
                    ClipboardDetailRow(label: "Group", value: groupTitle),
                    ClipboardDetailRow(label: "Type", value: ClipboardItemKind.snippet.rawValue),
                ] + sizeRows(for: snippet.content)
            )

        case let .folder(folder):
            let itemCount = folder.entries.filter { $0.pasteResult != nil }.count
            return ClipboardItemDetail(
                body: "",
                kind: .folder,
                rows: [
                    ClipboardDetailRow(label: "Type", value: ClipboardItemKind.folder.rawValue),
                    ClipboardDetailRow(label: "Items", value: "\(itemCount)"),
                ]
            )

        case .header, .back, .empty:
            return nil
        }
    }

    public static func detail(
        for item: ClipboardItem,
        dateFormatter: DateFormatter = defaultDateFormatter()
    ) -> ClipboardItemDetail {
        let kind = kind(for: item)
        var rows: [ClipboardDetailRow] = []

        if let sourceName = item.source?.name {
            rows.append(ClipboardDetailRow(label: "Source", value: sourceName))
        }

        rows.append(ClipboardDetailRow(label: "Type", value: kind.rawValue))

        if let image = item.image {
            rows.append(ClipboardDetailRow(label: "Dimensions", value: image.pixelSizeLabel))
            rows.append(ClipboardDetailRow(label: "Size", value: byteLabel(image.byteSize)))
        } else if !item.files.isEmpty {
            rows.append(ClipboardDetailRow(label: "Files", value: "\(item.files.count)"))

            if let first = item.files.first {
                rows.append(
                    ClipboardDetailRow(
                        label: "Location",
                        value: (first.path as NSString).deletingLastPathComponent
                    )
                )

                if !first.exists {
                    rows.append(ClipboardDetailRow(label: "State", value: "Missing"))
                }
            }
        } else {
            rows.append(contentsOf: sizeRows(for: item.plainText))
        }

        rows.append(
            ClipboardDetailRow(label: "Copied", value: dateFormatter.string(from: item.updatedAt))
        )

        return ClipboardItemDetail(
            body: item.previewText,
            kind: kind,
            sourceBundleID: item.source?.bundleID,
            image: item.image,
            files: item.files,
            rows: rows
        )
    }

    public static func byteLabel(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    public static func kind(for item: ClipboardItem) -> ClipboardItemKind {
        if !item.files.isEmpty {
            return .file
        }

        if item.image != nil || item.additionalRepresentations.contains(where: { isImageType($0.type) }) {
            return .image
        }

        if isLink(item.plainText) {
            return .link
        }

        if item.rtfData != nil || item.rtfdData != nil {
            return .richText
        }

        return .text
    }

    public static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let schemeEnd = trimmed.range(of: "://")?.lowerBound else {
            return false
        }

        let scheme = trimmed[trimmed.startIndex..<schemeEnd]
        guard let first = scheme.first, first.isLetter else {
            return false
        }

        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
            && trimmed.index(after: schemeEnd) < trimmed.endIndex
    }

    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func defaultDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static func sizeRows(for text: String) -> [ClipboardDetailRow] {
        [
            ClipboardDetailRow(label: "Characters", value: "\(text.count)"),
            ClipboardDetailRow(label: "Words", value: "\(wordCount(in: text))"),
        ]
    }

    private static func isImageType(_ type: String) -> Bool {
        let imageTypes = [
            "public.png",
            "public.jpeg",
            "public.tiff",
            "public.heic",
            "com.compuserve.gif",
            "com.adobe.pdf",
        ]

        return imageTypes.contains(type)
    }
}
