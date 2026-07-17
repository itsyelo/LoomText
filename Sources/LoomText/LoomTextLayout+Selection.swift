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
    /// The building block for pressed-state geometry (Task 07) and
    /// accessibility frames (Task 10).
    public func selectionRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let rangeEnd = range.location + range.length
        var rects: [CGRect] = []
        for line in lines {
            let lineEnd = line.range.location + line.range.length
            let start = max(range.location, line.range.location)
            let end = min(rangeEnd, lineEnd)
            guard start < end else { continue }
            let startX = CTLineGetOffsetForStringIndex(line.ctLine, start, nil)
            let endX = CTLineGetOffsetForStringIndex(line.ctLine, end, nil)
            let minX = min(startX, endX) + line.position.x
            let maxX = max(startX, endX) + line.position.x
            guard maxX > minX else { continue }
            rects.append(
                CGRect(x: minX, y: line.bounds.minY, width: maxX - minX, height: line.bounds.height)
            )
        }
        return rects
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

    /// Plain text for the copy pipeline: the substring of `text` over
    /// `range` (clamped to the string) with attachment placeholders
    /// (U+FFFC) removed — an attachment has no textual equivalent yet.
    public func plainText(in range: NSRange) -> String {
        let plain = text.string as NSString
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: plain.length))
        guard bounded.length > 0 else { return "" }
        return plain.substring(with: bounded).replacingOccurrences(of: "\u{FFFC}", with: "")
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
