import Foundation
import Yams

public enum ClipboardSettingsError: Error, CustomStringConvertible {
    case invalidBlock(String)
    case unknownSetting(String)

    public var description: String {
        switch self {
        case let .invalidBlock(message):
            return "Invalid clipboard config: \(message)"
        case let .unknownSetting(name):
            return "Unknown clipboard setting `\(name)`."
        }
    }
}

/// Options for what the clipboard does beyond recording and pasting.
public struct ClipboardSettings: Equatable, Sendable {
    public static let `default` = ClipboardSettings()

    /// Previewing a link means fetching it, so selecting an entry in history
    /// reaches the site it points at. Off leaves the picker showing the plain
    /// URL and touches the network never.
    public let linkPreviewsEnabled: Bool

    /// How many copies are kept. Text entries cost a few hundred bytes each,
    /// so the default is generous enough to search rather than to undo.
    public let historyLimit: Int

    public init(
        linkPreviewsEnabled: Bool = true,
        historyLimit: Int = ClipboardConstants.maxStoredItems
    ) {
        self.linkPreviewsEnabled = linkPreviewsEnabled
        self.historyLimit = historyLimit
    }
}

public enum ClipboardSettingsParser {
    private static let falseValues: Set<String> = ["false", "no", "off", "0"]
    private static let trueValues: Set<String> = ["true", "yes", "on", "1"]

    public static func parse(yaml contents: String) throws -> ClipboardSettings {
        guard let root = try Yams.compose(yaml: contents), let node = root["clipboard"] else {
            return .default
        }

        guard let mapping = node.mapping else {
            throw ClipboardSettingsError.invalidBlock("`clipboard` must be a mapping of settings.")
        }

        var settings = ClipboardSettings.default

        for pair in mapping {
            guard let name = pair.key.string else {
                throw ClipboardSettingsError.invalidBlock("Setting names must be strings.")
            }

            switch name {
            case "link-previews":
                settings = ClipboardSettings(
                    linkPreviewsEnabled: try boolean(from: pair.value, name: name),
                    historyLimit: settings.historyLimit
                )
            case "history-limit":
                settings = ClipboardSettings(
                    linkPreviewsEnabled: settings.linkPreviewsEnabled,
                    historyLimit: try count(from: pair.value, name: name)
                )
            default:
                throw ClipboardSettingsError.unknownSetting(name)
            }
        }

        return settings
    }

    private static func count(from node: Node, name: String) throws -> Int {
        guard let value = node.int, value > 0 else {
            throw ClipboardSettingsError.invalidBlock("Setting `\(name)` must be a whole number above zero.")
        }

        return value
    }

    private static func boolean(from node: Node, name: String) throws -> Bool {
        let rawValue = (node.string ?? "").trimmingCharacters(in: .whitespaces).lowercased()

        if falseValues.contains(rawValue) {
            return false
        }

        if trueValues.contains(rawValue) {
            return true
        }

        throw ClipboardSettingsError.invalidBlock("Setting `\(name)` must be true or false.")
    }
}
