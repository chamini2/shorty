import AppKit

/// The scroll view every list in Shorty uses.
///
/// A panel's list is always the same thing: no border, no background of its
/// own since the box behind it is frosted, and a thin overlay scroller that
/// fades out rather than taking a column of the width. Each list used to set
/// those for itself, with a different subset each time, which is how the
/// picker ended up with a wide scroller over its clock column.
@MainActor
class ShortyScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyShortyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func applyShortyStyle() {
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        // Lists scroll one way; sideways elasticity only lets a row drift.
        horizontalScrollElasticity = .none
        // Overlay rather than legacy: it floats over the rows and takes no
        // room of its own.
        scrollerStyle = .overlay
        verticalScroller?.controlSize = .small
    }
}
