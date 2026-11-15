import AppKit
import CryptoKit
import Foundation

/// An image kept beside the history file instead of inside it. The JSON holds
/// only this reference, so loading history never decodes megabytes of base64.
public struct ClipboardAsset: Codable, Equatable, Sendable {
    public let fileName: String
    public let type: String
    public let byteSize: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(fileName: String, type: String, byteSize: Int, pixelWidth: Int, pixelHeight: Int) {
        self.fileName = fileName
        self.type = type
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var pixelSizeLabel: String {
        "\(pixelWidth) × \(pixelHeight)"
    }
}

/// A file copied in Finder. Only the path is kept, so the entry costs no disk
/// and always pastes the current file, but it goes stale if the file moves.
public struct ClipboardFileReference: Codable, Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

public final class ClipboardAssetStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL = ClipboardAssetStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public static var defaultDirectory: URL {
        ClipboardHistoryStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("ClipboardAssets", isDirectory: true)
    }

    /// Content addressed, so the same image copied twice costs one file.
    @discardableResult
    public func store(data: Data, type: String, pixelWidth: Int, pixelHeight: Int) -> ClipboardAsset? {
        guard data.count <= ClipboardConstants.maxStoredImageBytes else {
            return nil
        }

        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileName = "\(digest).\(Self.fileExtension(for: type))"
        let fileURL = directory.appendingPathComponent(fileName)

        if !fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                return nil
            }
        }

        return ClipboardAsset(
            fileName: fileName,
            type: type,
            byteSize: data.count,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    public func url(for asset: ClipboardAsset) -> URL {
        directory.appendingPathComponent(asset.fileName)
    }

    public func data(for asset: ClipboardAsset) -> Data? {
        try? Data(contentsOf: url(for: asset))
    }

    public func image(for asset: ClipboardAsset) -> NSImage? {
        NSImage(contentsOf: url(for: asset))
    }

    /// Deletes files no history entry points at any more. Runs after a trim and
    /// at startup, so a crash cannot leak disk forever.
    ///
    /// `graceSeconds` spares files written moments ago: an image is stored
    /// before the entry referencing it is added, and a sweep in between would
    /// otherwise delete it.
    public func removeOrphans(keeping assets: [ClipboardAsset], graceSeconds: TimeInterval = 0) {
        let kept = Set(assets.map(\.fileName))

        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-graceSeconds)

        for name in names where !kept.contains(name) {
            let fileURL = directory.appendingPathComponent(name)

            if graceSeconds > 0,
               let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let modified = attributes[.modificationDate] as? Date,
               modified > cutoff {
                continue
            }

            try? fileManager.removeItem(at: fileURL)
        }
    }

    private static func fileExtension(for type: String) -> String {
        switch type {
        case "public.png":
            return "png"
        case "public.jpeg":
            return "jpg"
        case "public.tiff":
            return "tiff"
        case "com.compuserve.gif":
            return "gif"
        case "com.adobe.pdf":
            return "pdf"
        default:
            return "dat"
        }
    }
}
