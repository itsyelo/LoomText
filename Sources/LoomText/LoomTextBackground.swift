//
//  LoomTextBackground.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  The background/border subset of YYText's YYTextBorder.
//
//  CoreText's CTLineDraw ignores NSAttributedString.backgroundColor —
//  range backgrounds must be drawn by the layout. This attribute fills
//  and/or strokes a rounded rect behind each line fragment of its
//  range: mention capsules, pressed-state feedback, inline code chips,
//  outlined topic tags.
//

import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension NSAttributedString.Key {
    /// Draws a rounded background behind the range. Value: ``LoomTextBackground``.
    public static let loomTextBackground = NSAttributedString.Key("LoomTextBackground")
}

/// A rounded fill and/or stroke drawn behind a text range, per line
/// fragment.
///
/// `insets` shrink each fragment rect before drawing; negative values
/// grow it (a breathing capsule). Growth is ink, not layout — adjacent
/// glyphs are not pushed away — so keep negative insets to vertical
/// breathing (±1–2pt) and give a chip its horizontal room in the text
/// itself, where it participates in typesetting:
/// - **padding** (inside the border): begin and end the styled range
///   with a no-break space (`"\u{00A0}"`) — it widens the fragment box
///   and can never wrap into an orphan fragment;
/// - **margin** (between border and neighbors): plain spaces outside
///   the range.
/// A grown capsule that bleeds past the layout's edges just works —
/// ``LoomLabel`` renders it on an overflow layer
/// (``LoomTextLayout/inkOverflow``), leaving frame and alignment
/// untouched. Between lines, add paragraph `lineSpacing` or the growth
/// overlaps the previous line's ink. The stroke is inset by half its
/// width so it stays inside the box.
public final class LoomTextBackground: @unchecked Sendable {

    /// Fill color, or `nil` for an outline-only background. `CGColor`
    /// is immutable and thread-safe; resolve dynamic colors before
    /// constructing (pressed states are rebuilt per appearance through
    /// the trait-aware pipeline).
    public let fillColor: CGColor?

    /// Border color; `nil` draws no border.
    public let strokeColor: CGColor?

    /// Border width in points (only used when `strokeColor` is set).
    public let strokeWidth: CGFloat

    /// Corner radius, clamped to half the fragment's smaller dimension.
    public let cornerRadius: CGFloat

    /// Per-fragment insets applied before drawing; negative grows.
    public let insets: LoomEdgeInsets

    public init(
        fillColor: CGColor? = nil,
        strokeColor: CGColor? = nil,
        strokeWidth: CGFloat = 1,
        cornerRadius: CGFloat = 0,
        insets: LoomEdgeInsets = .zero
    ) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.insets = insets
    }
}

extension NSMutableAttributedString {
    /// Applies a rounded background behind `range`.
    public func loom_setBackground(_ background: LoomTextBackground, range: NSRange) {
        addAttribute(.loomTextBackground, value: background, range: range)
    }
}
