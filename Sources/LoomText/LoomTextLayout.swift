//
//  LoomTextLayout.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextLayout — horizontal core only.
//  Dropped relative to YYText: vertical form, custom/exclusion paths,
//  line position modifiers, truncation-token line construction (Task 08),
//  attachment extraction (Task 09).
//

import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit // decoration attribute keys (.underlineStyle etc.)
#endif

/// An immutable text layout: the result of running CoreText over an
/// attributed string within a ``LoomTextContainer``.
///
/// Build it on any thread — construction touches only CoreText, which is
/// thread-safe — then hand the same instance to measurement (Loom) and
/// rendering (`LoomLabel`). One layout, one source of truth.
///
/// Thread safety: every stored property is immutable after `init`.
/// CTFrame/CTLine carry no Sendable annotation but are immutable
/// CoreText objects, hence `@unchecked Sendable`.
public final class LoomTextLayout: @unchecked Sendable {

    /// Extended constraint used to work around CTFramesetterCreateFrame
    /// clipping on iOS 10+ (YYTextContainerMaxSize). Also the "unbounded"
    /// dimension callers use when measuring without a constraint.
    static let maxSize = CGSize(width: 0x100000, height: 0x100000)

    /// The attributed string this layout was built from (defensive copy).
    public let text: NSAttributedString

    /// The container this layout was built against (value copy).
    public let container: LoomTextContainer

    /// Laid-out lines, in visual order. Lines clipped by the container
    /// height or `maximumNumberOfRows` are not included.
    public let lines: [LoomTextLine]

    /// Number of visual rows actually laid out.
    public let rowCount: Int

    /// Range of `text` visible in this layout.
    public let visibleRange: NSRange

    /// The envelope of ``selectableRanges`` — for `.end` truncation (and
    /// untruncated text) the single visibly-selectable range: it excludes
    /// the last-line tail hidden behind the token (`visibleRange` keeps
    /// the full last-line range, YYText parity — but those glyphs are
    /// not drawn). For `.start`/`.middle` the envelope contains the
    /// hidden hole; geometry and copy exclude it via the spans.
    public let selectableRange: NSRange

    /// The visibly-drawn spans of `text`, in order. One span for plain
    /// and `.end`-truncated layouts; `.start`/`.middle` produce the
    /// spans around the token's hole (mapped from the truncated line's
    /// drawn runs, which for those types extend into the remainder of
    /// the text). Selection geometry, copy, and normalization exclude
    /// everything outside these spans.
    public let selectableRanges: [NSRange]

    /// Union of line bounds, in container coordinates (insets included
    /// in position, not expanded).
    public let textBoundingRect: CGRect

    /// Tight size needed to display the visible text, container insets
    /// added back, ceiled to integral points. Line-bounds union — trailing
    /// font leading is excluded, matching YYText semantics.
    public let textBoundingSize: CGSize

    /// Whether any text was clipped by height or `maximumNumberOfRows`.
    public let isTruncated: Bool

    /// When truncated (and `truncationType != .none`), the re-typeset
    /// last line ending in the truncation token. Drawing substitutes it
    /// for `lines[truncatedLine.index]`; hit-testing and bounding
    /// metrics keep using the original line (YYText parity).
    public let truncatedLine: LoomTextLine?

    /// The token actually used by `truncatedLine` (the container's, or
    /// the derived ellipsis).
    public let resolvedTruncationToken: NSAttributedString?

    /// Frame of the token within `truncatedLine`, in container
    /// coordinates. Only computed for `.end` truncation.
    public let truncationTokenRect: CGRect?

    /// Whether any run carries an underline or strikethrough — gates
    /// the decoration passes so undecorated text pays nothing.
    let hasDecorations: Bool

    /// How far grown ``LoomTextBackground`` capsules (negative insets)
    /// bleed past the layout box on each edge. `LoomLabel` renders this
    /// margin on an overflow layer so edge capsules are never clipped —
    /// the label's frame, text position, and `textBoundingSize` are all
    /// unaffected. Zero when no background grows.
    public let inkOverflow: LoomEdgeInsets

    /// Inline attachments across all *drawn* lines (the truncated line
    /// substitutes its original), with parallel ranges and frames.
    public let attachments: [LoomTextAttachment]
    public let attachmentRanges: [NSRange]
    public let attachmentRects: [CGRect]

    /// Vertical span (head/foot) of each row, adjacent edges averaged —
    /// the basis for row hit-testing.
    private let rowEdges: [(head: CGFloat, foot: CGFloat)]

    // MARK: - Init

    public convenience init?(containerSize: CGSize, text: NSAttributedString) {
        self.init(container: LoomTextContainer(size: containerSize), text: text)
    }

    public init?(container: LoomTextContainer, text: NSAttributedString) {
        guard container.size.width > 0, container.size.height > 0 else { return nil }
        guard let textCopy = text.copy() as? NSAttributedString else { return nil }
        self.text = textCopy
        self.container = container

        let maximumNumberOfRows = max(0, container.maximumNumberOfRows)

        // Constraint rect. CTFramesetterCreateFrame on iOS 10+ may clip
        // the last line for certain fonts when the height constraint is
        // tight; lay out against an extended height and clip lines back
        // to the real constraint manually (YYText's needFixLayoutSizeBug).
        var rect = CGRect(origin: .zero, size: container.size)
        let constraintRectBeforeExtended = rect.loomInset(by: container.insets).standardized
        rect.size.height = Self.maxSize.height
        rect = rect.loomInset(by: container.insets).standardized
        let pathBox = rect

        // CoreText lays out in a bottom-left-origin coordinate system.
        let flipped = rect.applying(CGAffineTransform(scaleX: 1, y: -1))
        let path = CGPath(rect: flipped, transform: nil)

        let framesetter = CTFramesetterCreateWithAttributedString(textCopy as CFAttributedString)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: textCopy.length), path, nil
        )

        let ctLines = CTFrameGetLines(frame)
        let ctLineCount = CFArrayGetCount(ctLines)
        var lineOrigins = [CGPoint](repeating: .zero, count: ctLineCount)
        if ctLineCount > 0 {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: ctLineCount), &lineOrigins)
        }

        var lines: [LoomTextLine] = []
        var textBoundingRect = CGRect.zero
        var rowIdx = -1
        var rowCount = 0
        var truncatedByConstraint = false

        for i in 0..<ctLineCount {
            let ctLine = unsafeBitCast(CFArrayGetValueAtIndex(ctLines, i), to: CTLine.self)
            let runs = CTLineGetGlyphRuns(ctLine)
            if CFArrayGetCount(runs) == 0 { continue }

            // Convert the baseline origin to top-left-origin coordinates.
            let ctOrigin = lineOrigins[i]
            let position = CGPoint(
                x: pathBox.minX + ctOrigin.x,
                y: pathBox.height + pathBox.minY - ctOrigin.y
            )

            let line = LoomTextLine(ctLine: ctLine, position: position, index: lines.count, row: rowIdx + 1)
            let bounds = line.bounds

            // Clip back to the pre-extension constraint (see above).
            if bounds.maxY > constraintRectBeforeExtended.maxY {
                truncatedByConstraint = true
                break
            }

            // Plain rectangular container: every line starts a new row.
            // (YYText's same-row detection only kicks in with exclusion
            // paths / custom paths, which v1 does not support.)
            rowIdx += 1
            lines.append(line)
            rowCount = rowIdx + 1

            if lines.count == 1 {
                textBoundingRect = bounds
            } else {
                textBoundingRect = textBoundingRect.union(bounds)
            }

            // Collapsed feed layouts (small maxRows, long text): stop as
            // soon as the cap is reached instead of building every line
            // and trimming afterwards (YYText builds all, then removes).
            // Clipped text is still detected by the visible-range check
            // below. Rows at or past the cap never join textBoundingRect,
            // so breaking here leaves it identical.
            if maximumNumberOfRows > 0, rowCount == maximumNumberOfRows {
                break
            }
        }

        var needTruncation = truncatedByConstraint
        if let last = lines.last, !needTruncation, last.range.location + last.range.length < textCopy.length {
            needTruncation = true
        }

        var truncatedLine: LoomTextLine?
        var resolvedToken: NSAttributedString?
        var tokenRect: CGRect?
        if needTruncation, container.truncationType != .none, let last = lines.last {
            (truncatedLine, resolvedToken, tokenRect) = Self.makeTruncatedLine(
                lastLine: last,
                text: textCopy,
                token: container.truncationToken,
                type: container.truncationType,
                width: constraintRectBeforeExtended.width
            ) ?? (nil, nil, nil)
        }

        // Row vertical edges, adjacent edges averaged (YYText's lineRowsEdge).
        var rowEdges: [(head: CGFloat, foot: CGFloat)] = []
        rowEdges.reserveCapacity(rowCount)
        for line in lines where line.row == rowEdges.count {
            rowEdges.append((head: line.bounds.minY, foot: line.bounds.maxY))
        }
        if rowEdges.count > 1 {
            for i in 1..<rowEdges.count {
                let mid = (rowEdges[i - 1].foot + rowEdges[i].head) * 0.5
                rowEdges[i - 1].foot = mid
                rowEdges[i].head = mid
            }
        }

        // Bounding size: add the container insets back and ceil. An empty
        // layout measures zero — it must not reserve the insets envelope
        // (deliberate divergence from YYText, which returns
        // (right, bottom) for empty text with non-zero insets).
        var boundingSize = CGSize.zero
        if !lines.isEmpty {
            let expanded = textBoundingRect.loomInset(by: container.insets.loomInverted).standardized
            var size = expanded.size
            size.width += expanded.minX
            size.height += expanded.minY
            size.width = max(0, size.width)
            size.height = max(0, size.height)
            boundingSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        }

        var visibleRange: NSRange
        let cfVisible = CTFrameGetVisibleStringRange(frame)
        visibleRange = NSRange(location: cfVisible.location, length: cfVisible.length)
        if needTruncation, let last = lines.last {
            visibleRange.length = last.range.location + last.range.length - visibleRange.location
        } else if lines.isEmpty {
            visibleRange = NSRange(location: 0, length: 0)
        }

        // Selection stops where the .end truncation token begins — the
        // glyphs behind it are not drawn, so they must not be selectable.
        var selectableRange = visibleRange
        if needTruncation, container.truncationType == .end,
            truncatedLine != nil, let tokenRect, let last = lines.last {
            let localX = tokenRect.minX - last.position.x
            let cut = CTLineGetStringIndexForPosition(last.ctLine, CGPoint(x: localX, y: 0))
            if cut != kCFNotFound {
                var bounded = max(visibleRange.location, min(cut, visibleRange.location + visibleRange.length))
                let plain = textCopy.string as NSString
                if bounded > 0, bounded < plain.length {
                    // Snap down so the boundary never splits a cluster.
                    let cluster = plain.rangeOfComposedCharacterSequence(at: bounded)
                    if cluster.location < bounded { bounded = cluster.location }
                }
                selectableRange = NSRange(
                    location: visibleRange.location,
                    length: max(0, bounded - visibleRange.location)
                )
            }
        }

        // .start/.middle hide a span *inside* the last line: the drawn
        // spans come from the truncated line's non-token runs, whose
        // indices are local to the extension text (the remainder, plus
        // a prepended token for .start).
        var selectableRanges = selectableRange.length > 0 ? [selectableRange] : []
        if needTruncation,
            container.truncationType == .start || container.truncationType == .middle,
            let truncated = truncatedLine, let last = lines.last {
            var spans: [NSRange] = []
            if last.range.location > visibleRange.location {
                spans.append(NSRange(
                    location: visibleRange.location,
                    length: last.range.location - visibleRange.location
                ))
            }
            let base = last.range.location
            let tokenShift = container.truncationType == .start ? (resolvedToken?.length ?? 0) : 0
            let runs = CTLineGetGlyphRuns(truncated.ctLine)
            for runIndex in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
                guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                    attributes[Self.tokenMarkerKey] == nil
                else { continue }
                let local = CTRunGetStringRange(run)
                let location = base + local.location - tokenShift
                guard location >= 0, location < textCopy.length else { continue }
                spans.append(NSRange(
                    location: location,
                    length: min(local.length, textCopy.length - location)
                ))
            }
            spans.sort { $0.location < $1.location }
            var merged: [NSRange] = []
            for span in spans where span.length > 0 {
                if let lastSpan = merged.last,
                    span.location <= lastSpan.location + lastSpan.length {
                    let upper = max(lastSpan.location + lastSpan.length, span.location + span.length)
                    merged[merged.count - 1] = NSRange(
                        location: lastSpan.location, length: upper - lastSpan.location
                    )
                } else {
                    merged.append(span)
                }
            }
            if let first = merged.first, let lastSpan = merged.last {
                selectableRanges = merged
                selectableRange = NSRange(
                    location: first.location,
                    length: lastSpan.location + lastSpan.length - first.location
                )
            }
        }

        var hasDecorations = false
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle] where !hasDecorations {
            for probe in [textCopy, resolvedToken] {
                guard let probe, probe.length > 0, !hasDecorations else { continue }
                probe.enumerateAttribute(key, in: NSRange(location: 0, length: probe.length)) { value, _, stop in
                    if let style = (value as? NSNumber)?.intValue, style != 0 {
                        hasDecorations = true
                        stop.pointee = true
                    }
                }
            }
        }

        var inkOverflow = LoomEdgeInsets.zero
        for probe in [textCopy, resolvedToken] {
            guard let probe, probe.length > 0 else { continue }
            probe.enumerateAttribute(
                .loomTextBackground, in: NSRange(location: 0, length: probe.length)
            ) { value, _, _ in
                guard let background = value as? LoomTextBackground else { return }
                inkOverflow.top = max(inkOverflow.top, -background.insets.top)
                inkOverflow.left = max(inkOverflow.left, -background.insets.left)
                inkOverflow.bottom = max(inkOverflow.bottom, -background.insets.bottom)
                inkOverflow.right = max(inkOverflow.right, -background.insets.right)
            }
        }

        var allAttachments: [LoomTextAttachment] = []
        var allAttachmentRanges: [NSRange] = []
        var allAttachmentRects: [CGRect] = []
        for line in lines {
            let effective = (truncatedLine?.index == line.index) ? truncatedLine! : line
            allAttachments.append(contentsOf: effective.attachments)
            allAttachmentRanges.append(contentsOf: effective.attachmentRanges)
            allAttachmentRects.append(contentsOf: effective.attachmentRects)
        }

        self.lines = lines
        self.rowCount = rowCount
        self.visibleRange = visibleRange
        self.selectableRange = selectableRange
        self.selectableRanges = selectableRanges
        self.hasDecorations = hasDecorations
        self.inkOverflow = inkOverflow
        self.textBoundingRect = textBoundingRect
        self.textBoundingSize = boundingSize
        self.isTruncated = needTruncation
        self.truncatedLine = truncatedLine
        self.resolvedTruncationToken = resolvedToken
        self.truncationTokenRect = tokenRect
        self.attachments = allAttachments
        self.attachmentRanges = allAttachmentRanges
        self.attachmentRects = allAttachmentRects
        self.rowEdges = rowEdges
    }

    /// Builds the token-terminated replacement for the last visible line
    /// (YYTextLayout's truncation construction, horizontal only).
    private static func makeTruncatedLine(
        lastLine: LoomTextLine,
        text: NSAttributedString,
        token: NSAttributedString?,
        type: LoomTextTruncationType,
        width: CGFloat
    ) -> (LoomTextLine, NSAttributedString, CGRect?)? {
        // Resolve the token: custom, or an ellipsis derived from the last
        // run's attributes (font scaled to 0.9× of the same face — YYText
        // switches to the system font; keeping the face reads better and
        // keeps metrics bounded by the host line).
        let resolvedToken: NSAttributedString
        if let token {
            resolvedToken = token
        } else {
            var attributes: [NSAttributedString.Key: Any] = [:]
            let runs = CTLineGetGlyphRuns(lastLine.ctLine)
            let runCount = CFArrayGetCount(runs)
            if runCount > 0 {
                let lastRun = unsafeBitCast(CFArrayGetValueAtIndex(runs, runCount - 1), to: CTRun.self)
                if let runAttributes = CTRunGetAttributes(lastRun) as? [NSAttributedString.Key: Any] {
                    let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
                    let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
                    if let font = runAttributes[fontKey] {
                        // swiftlint:disable:next force_cast
                        let ctFont = font as! CTFont
                        let scaled = CTFontCreateCopyWithAttributes(
                            ctFont, CTFontGetSize(ctFont) * 0.9, nil, nil
                        )
                        attributes[fontKey] = scaled
                    }
                    if let color = runAttributes[colorKey], CFGetTypeID(color as CFTypeRef) == CGColor.typeID {
                        // swiftlint:disable:next force_cast
                        let cgColor = color as! CGColor
                        if cgColor.alpha > 0 { attributes[colorKey] = cgColor }
                    }
                }
            }
            resolvedToken = NSAttributedString(string: "\u{2026}", attributes: attributes)
        }

        // The token instances fed to CoreText carry a private marker so
        // the token's runs can be found again inside the truncated line
        // — that locates the token rect for every truncation type. The
        // public resolvedTruncationToken stays clean.
        guard let markedToken = resolvedToken.mutableCopy() as? NSMutableAttributedString
        else { return nil }
        markedToken.addAttribute(
            Self.tokenMarkerKey, value: true,
            range: NSRange(location: 0, length: markedToken.length)
        )
        let tokenLine = CTLineCreateWithAttributedString(markedToken as CFAttributedString)

        let ctTruncationType: CTLineTruncationType
        switch type {
        case .start: ctTruncationType = .start
        case .middle: ctTruncationType = .middle
        default: ctTruncationType = .end
        }

        // .end extends with the last line's own text (visual result: the
        // line's prefix plus the token — pinned by tests). .start and
        // .middle extend with the whole remainder of the text, so the
        // token means "…the text continues": a `.start` path shows the
        // path's tail, `.middle` shows head…tail. The token is appended
        // for .end, prepended for .start, and inserted by CoreText
        // itself for .middle — extending it here would draw it twice.
        let sourceRange: NSRange
        switch type {
        case .start, .middle:
            sourceRange = NSRange(
                location: lastLine.range.location,
                length: text.length - lastLine.range.location
            )
        default:
            sourceRange = lastLine.range
        }
        guard let extendedText = text.attributedSubstring(from: sourceRange).mutableCopy()
            as? NSMutableAttributedString
        else { return nil }
        switch type {
        case .end:
            extendedText.append(markedToken)
        case .start:
            extendedText.insert(markedToken, at: 0)
        default:
            break
        }
        let extendedLine = CTLineCreateWithAttributedString(extendedText as CFAttributedString)

        guard let ctTruncated = CTLineCreateTruncatedLine(extendedLine, Double(width), ctTruncationType, tokenLine)
        else { return nil }

        let line = LoomTextLine(
            ctLine: ctTruncated,
            position: lastLine.position,
            index: lastLine.index,
            row: lastLine.row
        )

        var tokenRect: CGRect?
        var tokenMinX = CGFloat.greatestFiniteMagnitude
        var tokenMaxX = -CGFloat.greatestFiniteMagnitude
        var tokenAscent: CGFloat = 0
        var tokenDescent: CGFloat = 0
        let runs = CTLineGetGlyphRuns(ctTruncated)
        for runIndex in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
            guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                attributes[Self.tokenMarkerKey] != nil
            else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let runWidth = CGFloat(
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
            )
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            tokenMinX = min(tokenMinX, position.x)
            tokenMaxX = max(tokenMaxX, position.x + runWidth)
            tokenAscent = max(tokenAscent, ascent)
            tokenDescent = max(tokenDescent, descent)
        }
        if tokenMaxX > tokenMinX {
            tokenRect = CGRect(
                x: line.position.x + tokenMinX,
                y: line.position.y - tokenAscent,
                width: tokenMaxX - tokenMinX,
                height: tokenAscent + tokenDescent
            )
        }
        return (line, resolvedToken, tokenRect)
    }

    /// Private attribute marking token runs inside CT lines — never
    /// present on public attributed strings.
    static let tokenMarkerKey = NSAttributedString.Key("LoomTruncationTokenMarker")

    // MARK: - Hit testing (minimal set — extended in Task 07)

    /// The row containing `point`, or `nil` when the point falls outside
    /// every row's vertical span. Spans are half-open `[head, foot)` so a
    /// point on a shared edge belongs to exactly one row (YYText uses
    /// closed spans; the interior behavior is identical because adjacent
    /// edges are averaged to the same value).
    public func rowIndex(at point: CGPoint) -> Int? {
        rowEdges.firstIndex { point.y >= $0.head && point.y < $0.foot }
    }

    /// The line whose row span and horizontal bounds contain `point`.
    public func lineIndex(at point: CGPoint) -> Int? {
        guard let row = rowIndex(at: point) else { return nil }
        for line in lines where line.row == row {
            if point.x >= line.bounds.minX && point.x < line.bounds.maxX {
                return line.index
            }
        }
        return nil
    }

    /// The line visually closest to `point`. Returns `nil` only for an
    /// empty layout.
    public func closestLineIndex(to point: CGPoint) -> Int? {
        guard !lines.isEmpty else { return nil }
        if let exact = lineIndex(at: point) { return exact }
        let row: Int
        if let exactRow = rowIndex(at: point) {
            row = exactRow
        } else if point.y < rowEdges.first!.head {
            row = 0
        } else {
            row = rowEdges.count - 1
        }
        var best: (index: Int, distance: CGFloat)?
        for line in lines where line.row == row {
            let dx: CGFloat
            if point.x < line.bounds.minX {
                dx = line.bounds.minX - point.x
            } else if point.x > line.bounds.maxX {
                dx = point.x - line.bounds.maxX
            } else {
                dx = 0
            }
            if best == nil || dx < best!.distance {
                best = (line.index, dx)
            }
        }
        return best?.index
    }

    /// The character index in `text` closest to `point`, or `nil` for an
    /// empty layout. Basis for highlight hit-testing (Task 07).
    public func characterIndex(at point: CGPoint) -> Int? {
        guard let lineIndex = closestLineIndex(to: point) else { return nil }
        let line = lines[lineIndex]
        let local = CGPoint(x: point.x - line.position.x, y: 0)
        let index = CTLineGetStringIndexForPosition(line.ctLine, local)
        return index == kCFNotFound ? nil : index
    }
}
