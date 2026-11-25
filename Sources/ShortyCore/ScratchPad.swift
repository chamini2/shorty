import Foundation

/// A place to work text over before it goes somewhere.
///
/// Not a note and not a history: one page of text that stays as it was left,
/// for pasting something in, reshaping it, and copying out the version that
/// was wanted. The pasteboard is a bad workbench — every intermediate step
/// overwrites the thing being worked on — and this is the workbench.
///
/// Kept in `meta` rather than in a table: there is one of it, and losing it to
/// a restart would be a surprise even though nothing here is meant to last.
public final class ScratchPadStore {
    public static let metaKey = "scratch_pad"

    private let database: ShortyDatabase?

    public init(database: ShortyDatabase? = .shared) {
        self.database = database
    }

    public func text() -> String {
        database?.metaValue(for: Self.metaKey) ?? ""
    }

    public func setText(_ text: String) {
        // An empty pad is the absence of one, so it does not sit in `meta`
        // as a row holding nothing.
        database?.setMetaValue(text.isEmpty ? nil : text, for: Self.metaKey)
    }
}
