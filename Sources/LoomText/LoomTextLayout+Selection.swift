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
}
