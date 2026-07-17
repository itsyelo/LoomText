//
//  LoomTextLayout+Drawing.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextDrawText (horizontal path).
//

import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit // NSUnderlineStyle and the decoration attribute keys
#endif

extension LoomTextLayout {

    /// Draws the laid-out text into `context`.
    ///
    /// The context is assumed to use UIKit-style top-left-origin
    /// coordinates (as in `UIView.draw(_:)` or `UIGraphicsImageRenderer`).
    /// Rendering never re-typesets: it walks the precomputed `lines`.
    ///
    /// Runs on any thread — the layout is immutable and CoreText drawing
    /// is thread-safe. This is the primitive the async pipeline (Task 05)
    /// renders with on background queues.
    ///
    /// - Parameters:
    ///   - context: The target context.
    ///   - size: Canvas size used to anchor the CoreText coordinate flip.
    ///     Any value works as long as it matches the canvas the caller
    ///     draws into (the flip cancels out); pass the view/bitmap size.
    ///   - point: Top-left offset at which to draw.
    ///   - cancel: Polled after each line; return `true` to abort early.
    ///     The cancellation hook for sentinel-based async rendering.
    public func draw(
        in context: CGContext,
        size: CGSize,
        point: CGPoint = .zero,
        cancel: (() -> Bool)? = nil
    ) {
        guard !lines.isEmpty else { return }

        drawRangeBackgrounds(in: context, point: point, cancel: cancel)
        // YYText's decoration order: underline under the glyphs (a
        // descender must not be cut by the line), strikethrough above.
        if hasDecorations {
            drawDecorations(.underline, in: context, point: point, cancel: cancel)
        }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y + size.height)
        context.scaleBy(x: 1, y: -1)
        for var line in lines {
            if let truncatedLine, truncatedLine.index == line.index {
                line = truncatedLine
            }
            context.textMatrix = .identity
            context.textPosition = CGPoint(
                x: line.position.x,
                y: size.height - line.position.y
            )
            CTLineDraw(line.ctLine, context)
            if let cancel, cancel() { break }
        }
        context.restoreGState()

        if hasDecorations {
            drawDecorations(.strikethrough, in: context, point: point, cancel: cancel)
        }
        drawImageAttachments(in: context, point: point, cancel: cancel)
    }

    // MARK: - Decorations (Task 19)

    private enum DecorationKind {
        case underline
        case strikethrough

        var styleKey: NSAttributedString.Key {
            self == .underline ? .underlineStyle : .strikethroughStyle
        }

        var colorKey: NSAttributedString.Key {
            self == .underline ? .underlineColor : .strikethroughColor
        }
    }

    /// Draws underline/strikethrough lines — CTLineDraw ignores both
    /// (TextKit features, like `.backgroundColor`). Attributes are read
    /// per glyph run, so the truncated line and a custom token carry
    /// their own decorations without any string-index mapping. Style
    /// subset: single / thick / double; pattern bits are ignored.
    private func drawDecorations(
        _ kind: DecorationKind,
        in context: CGContext,
        point: CGPoint,
        cancel: (() -> Bool)?
    ) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        for var line in lines {
            if let cancel, cancel() { break }
            if let truncatedLine, truncatedLine.index == line.index {
                line = truncatedLine
            }
            let runs = CTLineGetGlyphRuns(line.ctLine)
            for runIndex in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
                guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                    let styleRaw = (attributes[kind.styleKey] as? NSNumber)?.intValue,
                    styleRaw != 0
                else { continue }

                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                guard width > 0 else { continue }
                let startX = line.position.x + position.x

                let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
                // swiftlint:disable:next force_cast
                let font = attributes[fontKey].map { $0 as! CTFont }
                    ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let thickness = max(CTFontGetUnderlineThickness(font), 0.5)
                let centerY: CGFloat
                switch kind {
                case .underline:
                    // Underline position is negative below the baseline.
                    centerY = line.position.y - CTFontGetUnderlinePosition(font)
                case .strikethrough:
                    centerY = line.position.y - CTFontGetXHeight(font) / 2
                }

                let color = Self.cgColor(from: attributes[kind.colorKey])
                    ?? Self.cgColor(from: attributes[.foregroundColor])
                    ?? Self.cgColor(
                        from: attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)]
                    )
                    ?? CGColor(gray: 0, alpha: 1)
                context.setFillColor(color)

                func strokeLine(at y: CGFloat, thickness: CGFloat) {
                    context.fill(CGRect(x: startX, y: y - thickness / 2, width: width, height: thickness))
                }
                switch styleRaw & 0x0F {
                case NSUnderlineStyle.thick.rawValue:
                    strokeLine(at: centerY, thickness: thickness * 2)
                case NSUnderlineStyle.double.rawValue & 0x0F:
                    strokeLine(at: centerY - thickness, thickness: thickness)
                    strokeLine(at: centerY + thickness, thickness: thickness)
                default:
                    strokeLine(at: centerY, thickness: thickness)
                }
            }
        }
        context.restoreGState()
    }

    private static func cgColor(from value: Any?) -> CGColor? {
        guard let value else { return nil }
        #if canImport(UIKit)
        if let color = value as? UIColor { return color.cgColor }
        #elseif canImport(AppKit)
        if let color = value as? NSColor { return color.cgColor }
        #endif
        if CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
            // swiftlint:disable:next force_cast
            return (value as! CGColor)
        }
        return nil
    }

    /// Fills ``LoomTextBackground`` capsules behind their ranges, one
    /// rounded rect per line fragment, before any glyph is drawn.
    /// Backgrounds inside the truncation token fill the token's rect.
    private func drawRangeBackgrounds(
        in context: CGContext,
        point: CGPoint,
        cancel: (() -> Bool)?
    ) {
        func fill(_ background: LoomTextBackground, rects: [CGRect]) {
            for rect in rects {
                let boxed = rect.loomInset(by: background.insets).standardized
                guard boxed.width > 0, boxed.height > 0 else { continue }
                let radius = min(background.cornerRadius, min(boxed.width, boxed.height) / 2)
                if let fillColor = background.fillColor {
                    let path = CGPath(
                        roundedRect: boxed, cornerWidth: radius, cornerHeight: radius, transform: nil
                    )
                    context.addPath(path)
                    context.setFillColor(fillColor)
                    context.fillPath()
                }
                if let strokeColor = background.strokeColor, background.strokeWidth > 0 {
                    // Inset by half the width so the stroke stays inside
                    // the fragment box.
                    let inset = background.strokeWidth / 2
                    let strokeBox = boxed.insetBy(dx: inset, dy: inset)
                    guard strokeBox.width > 0, strokeBox.height > 0 else { continue }
                    let strokeRadius = max(0, min(radius - inset, min(strokeBox.width, strokeBox.height) / 2))
                    let path = CGPath(
                        roundedRect: strokeBox, cornerWidth: strokeRadius,
                        cornerHeight: strokeRadius, transform: nil
                    )
                    context.addPath(path)
                    context.setStrokeColor(strokeColor)
                    context.setLineWidth(background.strokeWidth)
                    context.strokePath()
                }
            }
        }

        var hasAny = false
        if visibleRange.length > 0 {
            text.enumerateAttribute(.loomTextBackground, in: visibleRange) { value, _, stop in
                if value is LoomTextBackground {
                    hasAny = true
                    stop.pointee = true
                }
            }
        }
        let tokenBackground = resolvedTruncationToken.flatMap { token -> LoomTextBackground? in
            guard token.length > 0 else { return nil }
            return token.attribute(.loomTextBackground, at: 0, effectiveRange: nil) as? LoomTextBackground
        }
        guard hasAny || tokenBackground != nil else { return }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        if hasAny {
            text.enumerateAttribute(.loomTextBackground, in: visibleRange) { value, range, stop in
                guard let background = value as? LoomTextBackground else { return }
                if let cancel, cancel() {
                    stop.pointee = true
                    return
                }
                fill(background, rects: selectionRects(for: range))
            }
        }
        if let tokenBackground, let tokenRect = truncationTokenRect {
            fill(tokenBackground, rects: [tokenRect])
        }
        context.restoreGState()
    }

    /// Draws image-content attachments into the bitmap. View/layer
    /// content is never drawn — ``LoomLabel`` mounts those on the main
    /// thread after the bitmap commits.
    private func drawImageAttachments(
        in context: CGContext,
        point: CGPoint,
        cancel: (() -> Bool)?
    ) {
        guard !attachments.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        for (index, attachment) in attachments.enumerated() {
            if let cancel, cancel() { break }
            guard let content = attachment.content, let image = Self.cgImage(from: content) else { continue }
            let rect = attachmentRects[index]
            // Local flip: CGContext.draw is bottom-up, our coordinates
            // are top-down.
            context.saveGState()
            context.translateBy(x: 0, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func cgImage(from content: Any) -> CGImage? {
        #if canImport(UIKit)
        if let image = content as? UIImage { return image.cgImage }
        #endif
        if CFGetTypeID(content as CFTypeRef) == CGImage.typeID {
            // swiftlint:disable:next force_cast
            return (content as! CGImage)
        }
        return nil
    }
}
