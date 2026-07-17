//
//  LoomTextLine.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextLine (horizontal form only).
//

import CoreGraphics
import CoreText
import Foundation

/// One laid-out line of a ``LoomTextLayout``.
///
/// Immutable after construction — every metric is computed in `init`,
/// which is what makes the containing layout safe to share across
/// threads (`@unchecked Sendable`).
public final class LoomTextLine: @unchecked Sendable {

    /// The underlying CoreText line.
    public let ctLine: CTLine

    /// Baseline origin in the container's (top-left origin) coordinates.
    public let position: CGPoint

    /// Index of this line within ``LoomTextLayout/lines``.
    public let index: Int

    /// Visual row this line belongs to. Equal to `index` for plain
    /// rectangular containers; kept separate for future exclusion-path
    /// support where one row can host several line fragments.
    public let row: Int

    /// Range of the line within the source string.
    public let range: NSRange

    /// Typographic metrics reported by CoreText.
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    /// Typographic width, including trailing whitespace.
    public let lineWidth: CGFloat

    /// Width of trailing whitespace, already included in `lineWidth`.
    public let trailingWhitespaceWidth: CGFloat

    /// X offset of the first glyph relative to `position` (typically 0).
    public let firstGlyphPosition: CGFloat

    /// Line bounds in container coordinates: x is offset by the first
    /// glyph position, y spans ascent above to descent below the baseline.
    /// Font leading is intentionally excluded — this is what makes
    /// `textBoundingSize` a line-bounds union without trailing leading.
    public let bounds: CGRect

    /// Inline attachments in this line, with their string ranges and
    /// frames (container coordinates), in run order.
    public let attachments: [LoomTextAttachment]
    public let attachmentRanges: [NSRange]
    public let attachmentRects: [CGRect]

    public var width: CGFloat { bounds.width }
    public var height: CGFloat { bounds.height }
    public var top: CGFloat { bounds.minY }
    public var bottom: CGFloat { bounds.maxY }
    public var left: CGFloat { bounds.minX }
    public var right: CGFloat { bounds.maxX }
    public var size: CGSize { bounds.size }

    init(ctLine: CTLine, position: CGPoint, index: Int, row: Int) {
        self.ctLine = ctLine
        self.position = position
        self.index = index
        self.row = row

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.lineWidth = lineWidth

        let cfRange = CTLineGetStringRange(ctLine)
        self.range = NSRange(location: cfRange.location, length: cfRange.length)

        var firstGlyphPos: CGFloat = 0
        if CTLineGetGlyphCount(ctLine) > 0 {
            let runs = CTLineGetGlyphRuns(ctLine)
            // swiftlint:disable:next force_cast
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, 0), to: CTRun.self)
            var runPosition = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &runPosition)
            firstGlyphPos = runPosition.x
        }
        self.firstGlyphPosition = firstGlyphPos

        self.trailingWhitespaceWidth = CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))

        self.bounds = CGRect(
            x: position.x + firstGlyphPos,
            y: position.y - ascent,
            width: lineWidth,
            height: ascent + descent
        )

        // Attachment extraction (YYTextLine.reloadBounds, horizontal).
        var attachments: [LoomTextAttachment] = []
        var attachmentRanges: [NSRange] = []
        var attachmentRects: [CGRect] = []
        let runs = CTLineGetGlyphRuns(ctLine)
        for runIndex in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
            guard CTRunGetGlyphCount(run) > 0,
                  let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                  let attachment = attributes[.loomTextAttachment] as? LoomTextAttachment
            else { continue }

            var runPosition = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &runPosition)
            var runAscent: CGFloat = 0
            var runDescent: CGFloat = 0
            let runWidth = CGFloat(
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &runAscent, &runDescent, nil)
            )
            let rect = CGRect(
                x: position.x + runPosition.x,
                y: position.y - runPosition.y - runAscent,
                width: runWidth,
                height: runAscent + runDescent
            )
            let cfRunRange = CTRunGetStringRange(run)
            attachments.append(attachment)
            attachmentRanges.append(NSRange(location: cfRunRange.location, length: cfRunRange.length))
            attachmentRects.append(rect)
        }
        self.attachments = attachments
        self.attachmentRanges = attachmentRanges
        self.attachmentRects = attachmentRects
    }
}
