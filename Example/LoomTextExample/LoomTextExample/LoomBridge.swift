//
//  LoomBridge.swift
//  LoomTextExample
//
//  The Loom ↔ LoomText integration exemplar referenced by the README.
//  Two patterns, both keeping "typeset once" true:
//
//  1. `LoomTextMeasurer` — a `TextMeasuring` conformer so Loom measures
//     text with the same engine LoomLabel draws with.
//  2. `LTText(_:)` — when the view model has already built the
//     `LoomTextLayout`, hand Loom its exact size and give the label the
//     same instance. Zero re-typesetting anywhere.
//

import CoreGraphics
import Foundation
import Loom
import LoomText

/// Loom measures through LoomText: measurement == rendering, no
/// cross-engine alignment residual.
struct LoomTextMeasurer: TextMeasuring {
    static let shared = LoomTextMeasurer()

    func measure(
        _ attributedString: NSAttributedString,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        maxLines: Int
    ) -> CGSize {
        let cap: CGFloat = 0x100000
        let container = LoomTextContainer(
            size: CGSize(width: min(maxWidth, cap), height: min(maxHeight, cap)),
            maximumNumberOfRows: maxLines
        )
        return LoomTextLayout(container: container, text: attributedString)?.textBoundingSize ?? .zero
    }
}

/// A Loom node sized by a prebuilt ``LoomTextLayout`` — the view model
/// owns the layout; the cell assigns the same instance to `LoomLabel`.
func LTText(_ layout: LoomTextLayout) -> LoomNode {
    Measured { _, _ in layout.textBoundingSize }
}

// MARK: - Shared demo text helpers

enum DemoText {
    static let bodyFont = UIFont.systemFont(ofSize: 16)
    static let nameFont = UIFont.systemFont(ofSize: 15, weight: .semibold)

    static func expandToken() -> NSAttributedString {
        let token = NSMutableAttributedString(string: "\u{2026}全文", attributes: [
            .font: bodyFont,
            .foregroundColor: UIColor.systemBlue,
        ])
        token.loom_setHighlight(
            NSRange(location: 0, length: token.length),
            pressedAttributes: [
                .loomTextBackground: LoomTextBackground(
                    fillColor: UIColor.systemBlue.withAlphaComponent(0.15).cgColor,
                    cornerRadius: 4,
                    insets: LoomEdgeInsets(top: -1, left: -2, bottom: -1, right: -2)
                ),
            ],
            userInfo: ["action": "expand"]
        )
        return token
    }

    static func body(_ string: String, mention: String? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
        ])
        if let mention, let range = string.range(of: mention) {
            let nsRange = NSRange(range, in: string)
            text.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: nsRange)
            text.loom_setHighlight(
                nsRange,
                pressedAttributes: [
                    // Rounded capsule behind the pressed mention.
                    .loomTextBackground: LoomTextBackground(
                        fillColor: UIColor.systemBlue.withAlphaComponent(0.18).cgColor,
                        cornerRadius: 4,
                        insets: LoomEdgeInsets(top: -1, left: -3, bottom: -1, right: -3)
                    ),
                ],
                userInfo: ["action": "mention", "name": mention]
            )
        }
        return text
    }
}

import UIKit
