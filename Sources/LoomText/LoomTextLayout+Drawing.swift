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

        drawImageAttachments(in: context, point: point, cancel: cancel)
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
                let path = CGPath(
                    roundedRect: boxed, cornerWidth: radius, cornerHeight: radius, transform: nil
                )
                context.addPath(path)
                context.setFillColor(background.fillColor)
                context.fillPath()
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
