import Foundation

public enum ClipboardPickerActivationMode: Equatable, Sendable {
    case standard
    case plainText
    case joinedLines
    /// Put the entry on the pasteboard and stop there, for editing or
    /// re-copying rather than pasting into the app behind the picker.
    case copyOnly

    public static func fromModifiers(
        command: Bool,
        shift: Bool,
        option: Bool = false
    ) -> ClipboardPickerActivationMode {
        if shift {
            return .joinedLines
        }

        if command {
            return .copyOnly
        }

        if option {
            return .plainText
        }

        return .standard
    }
}
