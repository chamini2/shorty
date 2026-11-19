import Foundation

/// An app on disk, as the command box offers it.
public struct InstalledApplication: Equatable, Sendable, Identifiable {
    /// What the app is called, without the `.app`.
    public let name: String
    public let path: String
    /// Where it was found, shown under the name so two apps of the same name
    /// can be told apart.
    public let directoryName: String

    public init(name: String, path: String, directoryName: String) {
        self.name = name
        self.path = path
        self.directoryName = directoryName
    }

    public var id: String {
        "app.\(path)"
    }
}

/// Finds the apps installed on the machine.
///
/// A plain directory listing rather than Spotlight: the places apps live are
/// known, the answer is wanted in a few milliseconds while the box is opening,
/// and a query to the metadata server can take far longer than that.
public enum ApplicationScanner {
    /// Where macOS keeps apps people open. `CoreServices` is left out: it
    /// holds a hundred pieces of system machinery and a couple of real apps,
    /// and the machinery is only noise in a list you search by name.
    public static var defaultDirectories: [URL] {
        var directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            // Safari and its kin ship in a cryptex. `/Applications/Safari.app`
            // is only a link into here, and a directory listing does not
            // report it.
            "/System/Cryptexes/App/System/Applications",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        directories.append(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        )

        return directories
    }

    /// Every app in the given directories, one level down as well, since
    /// `/Applications` holds folders of apps. Sorted by name, with the first
    /// of a repeated name kept: a system app shadowed by a copy elsewhere
    /// should appear once.
    public static func scan(
        directories: [URL] = defaultDirectories,
        fileManager: FileManager = .default
    ) -> [InstalledApplication] {
        var found: [String: InstalledApplication] = [:]

        for directory in directories {
            for url in contents(of: directory, fileManager: fileManager) {
                if url.pathExtension == "app" {
                    add(url, in: directory, to: &found)
                    continue
                }

                // A folder such as `/Applications/Utilities`, one level only:
                // an app bundle is itself a directory and must not be walked.
                guard isDirectory(url, fileManager: fileManager) else {
                    continue
                }

                for nested in contents(of: url, fileManager: fileManager) where nested.pathExtension == "app" {
                    add(nested, in: url, to: &found)
                }
            }
        }

        return found.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func add(
        _ url: URL,
        in directory: URL,
        to found: inout [String: InstalledApplication]
    ) {
        let name = url.deletingPathExtension().lastPathComponent

        guard found[name] == nil else {
            return
        }

        found[name] = InstalledApplication(
            name: name,
            path: url.path,
            directoryName: directory.lastPathComponent
        )
    }

    private static func contents(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        return exists && isDirectory.boolValue
    }
}

/// The scan, kept for a while. Apps are installed rarely and the box is opened
/// often, so the list is read once and refreshed when it has had time to go
/// out of date.
public final class ApplicationIndex {
    public static let refreshInterval: TimeInterval = 60

    private let scan: @Sendable () -> [InstalledApplication]
    private var applications: [InstalledApplication] = []
    private var scannedAt: Date?

    public init(scan: @escaping @Sendable () -> [InstalledApplication] = { ApplicationScanner.scan() }) {
        self.scan = scan
    }

    public func current(now: Date = Date()) -> [InstalledApplication] {
        if let scannedAt, now.timeIntervalSince(scannedAt) < Self.refreshInterval {
            return applications
        }

        applications = scan()
        scannedAt = now

        return applications
    }
}
