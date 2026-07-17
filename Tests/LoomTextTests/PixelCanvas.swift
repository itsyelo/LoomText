//
//  PixelCanvas.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Pixel-analysis test infrastructure. Deliberately dependency-free:
//  zero-residual is a computable assertion (ink containment, byte
//  equality), not a golden-image comparison.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

/// A rendered layout plus ink analysis, in *logical* (point) coordinates
/// aligned with UIKit's top-left origin.
struct PixelCanvas {
    let pixels: [UInt8]          // RGBA, row 0 = top
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: CGFloat

    /// Alpha above this counts as ink; filters antialiasing whispers.
    static let inkAlphaThreshold: UInt8 = 24

    /// Renders `layout` at `point` (logical) into a canvas of logical
    /// size `canvas`, at `scale`. Buffer rows align with UIKit y.
    init(layout: LoomTextLayout, canvas: CGSize, point: CGPoint, scale: CGFloat) throws {
        let pw = Int(ceil(canvas.width * scale))
        let ph = Int(ceil(canvas.height * scale))
        var data = [UInt8](repeating: 0, count: pw * ph * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: pw, height: ph,
                    bitsPerComponent: 8, bytesPerRow: pw * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            // Pre-flip so the context behaves like a UIKit drawing
            // context (top-left origin); buffer row == UIKit y * scale.
            context.translateBy(x: 0, y: CGFloat(ph))
            context.scaleBy(x: 1, y: -1)
            context.scaleBy(x: scale, y: scale)
            layout.draw(in: context, size: canvas, point: point)
        }
        self.pixels = data
        self.pixelWidth = pw
        self.pixelHeight = ph
        self.scale = scale
    }

    /// Tight bounding box of all ink, in logical points. `nil` if blank.
    var inkRect: CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<pixelHeight {
            let rowBase = y * pixelWidth * 4
            for x in 0..<pixelWidth where pixels[rowBase + x * 4 + 3] > Self.inkAlphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    var inkCount: Int {
        stride(from: 3, to: pixels.count, by: 4).reduce(0) {
            $0 + (pixels[$1] > Self.inkAlphaThreshold ? 1 : 0)
        }
    }

    /// Raw bytes of the logical-coordinate row band [fromY, toY).
    func rowBand(fromY: CGFloat, toY: CGFloat) -> ArraySlice<UInt8> {
        let start = max(0, Int(fromY * scale)) * pixelWidth * 4
        let end = min(pixelHeight, Int(toY * scale)) * pixelWidth * 4
        return pixels[start..<max(start, end)]
    }
}

// MARK: - Shared attributed-string builders

enum TestText {
    static func plain(_ string: String, fontName: String = "Helvetica", size: CGFloat = 16) -> NSAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    static func withLineSpacing(_ string: String, spacing: CGFloat, size: CGFloat = 16) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var lineSpacing = spacing
        let settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment,
                valueSize: MemoryLayout<CGFloat>.size,
                value: &lineSpacing
            )
        ]
        let style = CTParagraphStyleCreate(settings, settings.count)
        return NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
    }
}
