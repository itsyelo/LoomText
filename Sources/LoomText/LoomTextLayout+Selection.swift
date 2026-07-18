//
//  LoomTextLayout+Selection.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreGraphics
import CoreText
import Foundation

extension LoomTextLayout {

    /// Per-line rectangles covering `range`, in container coordinates.
    /// The building block for pressed-state geometry (Task 07),
    /// accessibility frames (Task 10), and the selection overlay.
    ///
    /// Glyph-accurate for bidirectional text (Task 22): each glyph run
    /// contributes the horizontal span of its glyphs inside `range`, so
    /// a logical range crossing an LTR↔RTL boundary yields the correct
    /// discontiguous segments. Touching segments merge — a plain LTR
    /// line still produces exactly one rect. Glyph positions/advances
    /// are used instead of caret offsets to sidestep the bidi-boundary
    /// caret ambiguity; a ligature glyph belongs to the range when its
    /// first character does (YYText's approximation).
    public func selectionRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        // A layout with a hidden hole (.start/.middle truncation)
        // contributes no geometry for it — clip to the visible spans.
        if selectableRanges.count > 1 {
            return selectableRanges.flatMap { span -> [CGRect] in
                let clipped = NSIntersectionRange(range, span)
                guard clipped.length > 0 else { return [] }
                return segmentSelectionRects(for: clipped)
            }
        }
        return segmentSelectionRects(for: range)
    }

    private func segmentSelectionRects(for range: NSRange) -> [CGRect] {
        let rangeEnd = range.location + range.length
        var rects: [CGRect] = []
        for line in lines {
            // A .start/.middle-substituted line draws the remainder of
            // the text, not the original line — take its geometry from
            // the drawn glyphs so highlights match what is on screen.
            if let truncatedLine, truncatedLine.index == line.index, selectableRanges.count > 1 {
                rects.append(contentsOf: substitutedLineRects(
                    for: range, original: line, truncated: truncatedLine
                ))
                continue
            }
            let lineEnd = line.range.location + line.range.length
            let start = max(range.location, line.range.location)
            let end = min(rangeEnd, lineEnd)
            guard start < end else { continue }

            var segments: [CGRect] = []
            let runs = CTLineGetGlyphRuns(line.ctLine)
            for runIndex in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
                let glyphCount = CTRunGetGlyphCount(run)
                guard glyphCount > 0 else { continue }
                let runRange = CTRunGetStringRange(run)
                guard runRange.location < end, runRange.location + runRange.length > start
                else { continue }

                var indices = [CFIndex](repeating: 0, count: glyphCount)
                var positions = [CGPoint](repeating: .zero, count: glyphCount)
                var advances = [CGSize](repeating: .zero, count: glyphCount)
                let whole = CFRange(location: 0, length: glyphCount)
                CTRunGetStringIndices(run, whole, &indices)
                CTRunGetPositions(run, whole, &positions)
                CTRunGetAdvances(run, whole, &advances)

                var minX = CGFloat.greatestFiniteMagnitude
                var maxX = -CGFloat.greatestFiniteMagnitude
                for glyph in 0..<glyphCount where indices[glyph] >= start && indices[glyph] < end {
                    minX = min(minX, positions[glyph].x)
                    maxX = max(maxX, positions[glyph].x + advances[glyph].width)
                }
                guard maxX > minX else { continue }
                segments.append(CGRect(
                    x: line.position.x + minX,
                    y: line.bounds.minY,
                    width: maxX - minX,
                    height: line.bounds.height
                ))
            }

            segments.sort { $0.minX < $1.minX }
            rects.append(contentsOf: Self.mergeTouching(segments))
        }
        return rects
    }

    private static func mergeTouching(_ segments: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for segment in segments {
            if let last = merged.last, segment.minX <= last.maxX + 0.5 {
                merged[merged.count - 1] = last.union(segment)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Selection geometry for the truncated line of a `.start`/`.middle`
    /// layout: scan the *drawn* line's glyph runs (token runs excluded),
    /// mapping their extension-local string indices back to the full
    /// text — the same mapping ``selectableRanges`` was built with.
    private func substitutedLineRects(
        for range: NSRange,
        original: LoomTextLine,
        truncated: LoomTextLine
    ) -> [CGRect] {
        let base = original.range.location
        let tokenShift = container.truncationType == .start
            ? (resolvedTruncationToken?.length ?? 0) : 0
        let rangeEnd = range.location + range.length
        var segments: [CGRect] = []
        let runs = CTLineGetGlyphRuns(truncated.ctLine)
        for runIndex in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                attributes[Self.tokenMarkerKey] == nil
            else { continue }

            var indices = [CFIndex](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            let whole = CFRange(location: 0, length: glyphCount)
            CTRunGetStringIndices(run, whole, &indices)
            CTRunGetPositions(run, whole, &positions)
            CTRunGetAdvances(run, whole, &advances)

            var minX = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            for glyph in 0..<glyphCount {
                let absolute = base + indices[glyph] - tokenShift
                guard absolute >= range.location, absolute < rangeEnd else { continue }
                minX = min(minX, positions[glyph].x)
                maxX = max(maxX, positions[glyph].x + advances[glyph].width)
            }
            guard maxX > minX else { continue }
            segments.append(CGRect(
                x: truncated.position.x + minX,
                y: truncated.bounds.minY,
                width: maxX - minX,
                height: truncated.bounds.height
            ))
        }
        segments.sort { $0.minX < $1.minX }
        return Self.mergeTouching(segments)
    }

    /// Union of ``selectionRects(for:)`` — the callback rect for taps.
    public func rect(for range: NSRange) -> CGRect {
        let rects = selectionRects(for: range)
        guard var union = rects.first else { return .null }
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }
        return union
    }

    // MARK: - Selection ranges (Task 15)

    /// The composed character sequence (grapheme cluster) containing
    /// `index`, or `nil` when `index` lies outside `text`.
    public func graphemeClusterRange(at index: Int) -> NSRange? {
        let plain = text.string as NSString
        guard index >= 0, index < plain.length else { return nil }
        return plain.rangeOfComposedCharacterSequence(at: index)
    }

    /// The locale-aware word containing `index` — CJK segments into
    /// words, not single characters (`CFStringTokenizer`, word-boundary
    /// units). Indices outside `selectableRange` clamp to its nearest
    /// character. Where no word token exists (whitespace) or the token
    /// is whitespace-only, the fallback is the grapheme cluster at
    /// `index`. The result passes through
    /// ``normalizedSelectionRange(for:)``; `nil` when nothing is
    /// selectable.
    public func wordRange(at index: Int) -> NSRange? {
        let bounds = selectableRange
        guard bounds.length > 0 else { return nil }
        let plain = text.string as NSString
        let clamped = max(bounds.location, min(index, bounds.location + bounds.length - 1))

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            plain as CFString,
            CFRange(location: 0, length: plain.length),
            kCFStringTokenizerUnitWordBoundary,
            CFLocaleCopyCurrent()
        )
        var word: NSRange?
        if !CFStringTokenizerGoToTokenAtIndex(tokenizer, clamped).isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if tokenRange.location != kCFNotFound, tokenRange.length > 0 {
                let candidate = NSRange(location: tokenRange.location, length: tokenRange.length)
                let content = plain.substring(with: candidate)
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    word = candidate
                }
            }
        }
        let resolved = word ?? graphemeClusterRange(at: clamped)
        guard let resolved else { return nil }
        return normalizedSelectionRange(for: resolved)
    }

    /// Plain text for the copy pipeline: what is *visible* of `range` —
    /// the intersection with ``selectableRanges``, concatenated across a
    /// truncation hole — with each attachment placeholder (U+FFFC)
    /// replaced by its ``LoomTextAttachment/altText``, or stripped when
    /// the attachment provides none. Hidden text never copies.
    public func plainText(in range: NSRange) -> String {
        selectableRanges.map { span -> String in
            let clipped = NSIntersectionRange(range, span)
            guard clipped.length > 0 else { return "" }
            return plainTextSegment(in: clipped)
        }.joined()
    }

    private func plainTextSegment(in range: NSRange) -> String {
        let plain = text.string as NSString
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: plain.length))
        guard bounded.length > 0 else { return "" }
        let substring = text.attributedSubstring(from: bounded)
        guard substring.string.contains("\u{FFFC}") else { return substring.string }
        // Collect first, replace back to front — replacements of a
        // different length would shift the ranges mid-enumeration.
        var replacements: [(NSRange, String)] = []
        substring.enumerateAttribute(
            .loomTextAttachment, in: NSRange(location: 0, length: substring.length)
        ) { value, attachmentRange, _ in
            guard let attachment = value as? LoomTextAttachment else { return }
            replacements.append((attachmentRange, attachment.altText ?? ""))
        }
        let result = NSMutableString(string: substring.string)
        for (attachmentRange, alt) in replacements.reversed() {
            result.replaceCharacters(in: attachmentRange, with: alt)
        }
        // Placeholders without our attachment attribute still strip.
        return (result as String).replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Normalizes a candidate selection: intersects it with
    /// `selectableRange`, then expands both endpoints outward to
    /// grapheme-cluster boundaries so composed sequences (ZWJ emoji,
    /// combining marks) are never split. Returns `nil` when the
    /// intersection is empty — a zero-length selection is "no
    /// selection" for a read-only label.
    public func normalizedSelectionRange(for range: NSRange) -> NSRange? {
        let bounds = selectableRange
        guard bounds.length > 0, range.location != NSNotFound else { return nil }
        let plain = text.string as NSString
        var start = max(range.location, bounds.location)
        var end = min(range.location + range.length, bounds.location + bounds.length)
        guard start < end, start < plain.length else { return nil }

        // Endpoints inside a truncation hole snap outward to its edges.
        if selectableRanges.count > 1 {
            if !selectableRanges.contains(where: { $0.location <= start && start < $0.location + $0.length }) {
                guard let next = selectableRanges.first(where: { $0.location >= start })
                else { return nil }
                start = next.location
            }
            if !selectableRanges.contains(where: { $0.location < end && end <= $0.location + $0.length }) {
                guard let previous = selectableRanges.last(where: { $0.location + $0.length <= end })
                else { return nil }
                end = previous.location + previous.length
            }
            guard start < end else { return nil }
        }

        start = plain.rangeOfComposedCharacterSequence(at: start).location
        let endCluster = plain.rangeOfComposedCharacterSequence(at: end - 1)
        end = endCluster.location + endCluster.length

        // selectableRange endpoints are cluster boundaries themselves,
        // so this re-clip is defensive only.
        start = max(start, bounds.location)
        end = min(end, bounds.location + bounds.length)
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
