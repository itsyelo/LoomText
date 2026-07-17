//
//  LoomTextBackground.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  The background-capsule subset of YYText's YYTextBorder.
//
//  CoreText's CTLineDraw ignores NSAttributedString.backgroundColor —
//  range backgrounds must be drawn by the layout. This attribute fills
//  a rounded rect behind each line fragment of its range: mention
//  capsules, pressed-state feedback, inline code chips.
//

import CoreGraphics
import Foundation

extension NSAttributedString.Key {
    /// Fills a rounded background behind the range. Value: ``LoomTextBackground``.
    public static let loomTextBackground = NSAttributedString.Key("LoomTextBackground")
}

/// A rounded fill drawn behind a text range, per line fragment.
///
/// `insets` shrink each fragment rect before filling; negative values
/// grow it (a breathing capsule). Growing draws outside the line box —
/// keep within the label's padding or the capsule clips at its edges.
public final class LoomTextBackground: @unchecked Sendable {

    /// Fill color. `CGColor` is immutable and thread-safe; resolve
    /// dynamic colors before constructing (pressed states are rebuilt
    /// per appearance through the trait-aware pipeline).
    public let fillColor: CGColor

    /// Corner radius, clamped to half the fragment's smaller dimension.
    public let cornerRadius: CGFloat

    /// Per-fragment insets applied before filling; negative grows.
    public let insets: LoomEdgeInsets

    public init(fillColor: CGColor, cornerRadius: CGFloat = 0, insets: LoomEdgeInsets = .zero) {
        self.fillColor = fillColor
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
