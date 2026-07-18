//
//  LoomTextContainer.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextContainer (horizontal form only).
//

import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
/// Edge insets type used by LoomText. `UIEdgeInsets` on UIKit platforms.
public typealias LoomEdgeInsets = UIEdgeInsets
#else
/// Edge insets type used by LoomText. `NSEdgeInsets` on macOS (test/CI builds).
public typealias LoomEdgeInsets = NSEdgeInsets

extension NSEdgeInsets {
    /// Zero insets, mirroring `UIEdgeInsets.zero`.
    public static var zero: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}
#endif

/// How the last visible line ends when text does not fit the container.
///
/// All three token styles render, position their
/// ``LoomTextLayout/truncationTokenRect``, and support token
/// highlights/backgrounds/accessibility. Selection and copy are
/// hole-aware: the hidden span (`.end`'s tail, or the interior hole of
/// `.start`/`.middle`) contributes no selection geometry and never
/// copies — see ``LoomTextLayout/selectableRanges``. Hit-testing on
/// the redrawn tail of `.start`/`.middle` remains approximate (the
/// drawn glyphs come from the text's remainder while hit-testing keeps
/// the original line, YYText parity).
public enum LoomTextTruncationType: Sendable {
    case none
    case start
    case middle
    case end
}

/// Describes the geometry constraints a ``LoomTextLayout`` is built against.
///
/// Value semantics: copying the container detaches it from the original.
/// The `truncationToken` is defensively copied on set, so a container is
/// safe to send across threads once constructed.
public struct LoomTextContainer: @unchecked Sendable {

    /// Constrained size of the layout area, including `insets`.
    public var size: CGSize

    /// Insets applied inside `size` before laying out text.
    public var insets: LoomEdgeInsets

    /// Maximum number of visual rows. `0` means unlimited.
    public var maximumNumberOfRows: Int

    /// Truncation style applied when text exceeds the container.
    public var truncationType: LoomTextTruncationType

    /// Custom truncation token drawn at the truncation position.
    /// `nil` uses a plain ellipsis. Rendering lands in Task 08; the field
    /// participates in layout identity from day one.
    public var truncationToken: NSAttributedString? {
        get { _truncationToken }
        set { _truncationToken = newValue?.copy() as? NSAttributedString }
    }
    private var _truncationToken: NSAttributedString?

    public init(
        size: CGSize,
        insets: LoomEdgeInsets = .zero,
        maximumNumberOfRows: Int = 0,
        truncationType: LoomTextTruncationType = .end,
        truncationToken: NSAttributedString? = nil
    ) {
        self.size = size
        self.insets = insets
        self.maximumNumberOfRows = maximumNumberOfRows
        self.truncationType = truncationType
        self._truncationToken = truncationToken?.copy() as? NSAttributedString
    }
}

// MARK: - Internal geometry helpers

extension LoomEdgeInsets {
    /// Cross-platform zero check (`NSEdgeInsets` is not `Equatable`).
    var loomIsZero: Bool {
        top == 0 && left == 0 && bottom == 0 && right == 0
    }
}

extension CGRect {
    /// Cross-platform `inset(by:)` — shrinks by positive insets, grows by negative.
    func loomInset(by insets: LoomEdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}

extension LoomEdgeInsets {
    /// Negates every edge, mirroring YYTextUIEdgeInsetsInvert.
    var loomInverted: LoomEdgeInsets {
        LoomEdgeInsets(top: -top, left: -left, bottom: -bottom, right: -right)
    }
}
