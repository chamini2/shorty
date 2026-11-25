import Foundation
import Vision

/// Reads the words in a copied picture.
///
/// A screenshot of an error message is usually copied for what it says, and
/// without this the entry is a thumbnail with no text: nothing to show in the
/// list and nothing to search. Vision is in the SDK, so this costs no
/// dependency.
///
/// What it reads is a label and a search key, never what gets pasted. The
/// recognised text is kept apart from the pasteboard's own in `ocrText`, so
/// pasting a screenshot still pastes the picture, and the identity of an
/// entry — a hash of what was copied — does not change when the reading
/// arrives later.
public enum ClipboardTextRecognition {
    /// Long enough for a stack trace, short enough that a dense screenshot
    /// does not become the largest thing in the database.
    static let maximumCharacters = 4_000

    /// The words in `data`, or nil when there is nothing legible.
    ///
    /// Blocking, and slow enough to matter: callers run it off the main
    /// thread, after the entry has been written.
    public static func text(in data: Data) -> String? {
        let request = VNRecognizeTextRequest()
        // Accurate rather than fast: a misread word in a label is worse than
        // waiting, since nothing here is on the copy path.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        guard (try? VNImageRequestHandler(data: data, options: [:]).perform([request])) != nil else {
            return nil
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return nil
        }

        return String(text.prefix(maximumCharacters))
    }
}
