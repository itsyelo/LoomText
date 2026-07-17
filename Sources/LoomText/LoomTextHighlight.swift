//
//  LoomTextHighlight.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextHighlight (display-side subset).
//

import Foundation

extension NSAttributedString.Key {
    /// Marks a range as an interactive highlight. Value: ``LoomTextHighlight``.
    public static let loomTextHighlight = NSAttributedString.Key("LoomTextHighlight")
}

/// An interactive text range: links, mentions, hashtags, "…more" tokens.
///
/// `attributes` are applied *over* the range while the user presses it
/// (typically a foreground/background color change). `userInfo` carries
/// whatever the app needs to route the tap — a URL, a user id — and is
/// handed back through the label's tap/long-press actions.
///
/// Immutable and reference-typed so it can live inside attributed
/// strings that cross threads; the pressed-state attributes must be
/// main-thread-agnostic values (colors, fonts — not views).
public final class LoomTextHighlight: @unchecked Sendable {

    /// Attributes overlaid on the range while pressed.
    public let attributes: [NSAttributedString.Key: Any]

    /// App-defined payload, returned in tap callbacks.
    public let userInfo: [AnyHashable: Any]?

    public init(attributes: [NSAttributedString.Key: Any], userInfo: [AnyHashable: Any]? = nil) {
        self.attributes = attributes
        self.userInfo = userInfo
    }
}

extension NSMutableAttributedString {
    /// Marks `range` as an interactive highlight with the given
    /// pressed-state attributes.
    public func loom_setHighlight(
        _ range: NSRange,
        pressedAttributes: [NSAttributedString.Key: Any],
        userInfo: [AnyHashable: Any]? = nil
    ) {
        addAttribute(
            .loomTextHighlight,
            value: LoomTextHighlight(attributes: pressedAttributes, userInfo: userInfo),
            range: range
        )
    }
}

extension LoomTextLayout {

    /// The highlight containing `point`, with its full effective range.
    /// Uses exact line containment — points in empty space beside a line
    /// do not hit. Points inside the truncation token never match an
    /// inline highlight (the token covers those glyphs); use
    /// ``truncationTokenHighlight(at:)``.
    public func highlight(at point: CGPoint) -> (highlight: LoomTextHighlight, range: NSRange)? {
        if let tokenRect = truncationTokenRect, tokenRect.contains(point) { return nil }
        guard lineIndex(at: point) != nil,
              let index = characterIndex(at: point),
              index < text.length
        else { return nil }
        var effectiveRange = NSRange(location: 0, length: 0)
        guard let value = text.attribute(
            .loomTextHighlight, at: index,
            longestEffectiveRange: &effectiveRange,
            in: NSRange(location: 0, length: text.length)
        ) as? LoomTextHighlight else { return nil }
        return (value, effectiveRange)
    }

    /// The highlight inside the truncation token containing `point`.
    /// `range` is within the *token's* string, and the geometry callback
    /// rect is ``truncationTokenRect``.
    public func truncationTokenHighlight(
        at point: CGPoint
    ) -> (highlight: LoomTextHighlight, range: NSRange)? {
        guard let tokenRect = truncationTokenRect,
              tokenRect.contains(point),
              let token = resolvedTruncationToken,
              token.length > 0
        else { return nil }
        var effectiveRange = NSRange(location: 0, length: 0)
        guard let value = token.attribute(
            .loomTextHighlight, at: 0,
            longestEffectiveRange: &effectiveRange,
            in: NSRange(location: 0, length: token.length)
        ) as? LoomTextHighlight else { return nil }
        return (value, effectiveRange)
    }
}
