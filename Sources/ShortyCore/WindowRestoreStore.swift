import CoreGraphics
import Foundation

/// Remembers where a window was before Shorty first moved it, so it can be put
/// back. Only the first move is recorded: after half, half again and maximize,
/// restoring should return to where you started, not to the previous step.
///
/// Generic over the key so it can be tested without a window server; the mover
/// keys it by accessibility element.
public struct WindowRestoreStore<Key: Hashable> {
    private var frames: [Key: CGRect] = [:]
    private var order: [Key] = []
    private let limit: Int

    public init(limit: Int = 32) {
        self.limit = limit
    }

    public var count: Int {
        frames.count
    }

    /// Keeps the earliest frame for a window and ignores later ones.
    public mutating func record(_ frame: CGRect, for key: Key) {
        guard frames[key] == nil else {
            return
        }

        frames[key] = frame
        order.append(key)

        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            frames.removeValue(forKey: oldest)
        }
    }

    public func frame(for key: Key) -> CGRect? {
        frames[key]
    }

    @discardableResult
    public mutating func forget(_ key: Key) -> CGRect? {
        guard let frame = frames.removeValue(forKey: key) else {
            return nil
        }

        order.removeAll { $0 == key }
        return frame
    }
}
