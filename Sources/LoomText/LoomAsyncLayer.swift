//
//  LoomAsyncLayer.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextAsyncLayer.
//

#if canImport(UIKit)
import UIKit

/// One display pass, produced by the layer's delegate.
///
/// - `willDisplay` / `didDisplay` run on the main thread.
/// - `display` may run on a background render queue; it must only touch
///   the immutable state it captured (a `LoomTextLayout`, colors, …).
public struct LoomAsyncLayerDisplayTask {

    /// Called on the main thread before the render is submitted.
    public var willDisplay: ((CALayer) -> Void)?

    /// Draws the content. `isCancelled` should be polled between
    /// expensive steps; when it returns `true` the result is discarded.
    public var display: (@Sendable (_ context: CGContext, _ size: CGSize, _ isCancelled: @escaping @Sendable () -> Bool) -> Void)?

    /// Called on the main thread after the pass ends. `finished` is
    /// `false` when the render was cancelled by a newer pass.
    public var didDisplay: ((CALayer, _ finished: Bool) -> Void)?

    /// Traits the render resolves dynamic colors against. Capture the
    /// hosting view's `traitCollection` when the task is built — the
    /// background render wraps drawing in `performAsCurrent`, so
    /// dark-mode `UIColor`s resolve to the appearance the view had at
    /// submission, not whatever the render thread defaults to.
    public var traitCollection: UITraitCollection?

    /// Extra canvas beyond the layer bounds on each edge. Non-zero
    /// values render onto an overflow sublayer that extends past the
    /// layer, so ink bleeding out of the layout box (grown background
    /// capsules) is not clipped. The `display` closure receives the
    /// padded size and is responsible for drawing offset by
    /// `(left, top)`.
    public var inkOverflow: UIEdgeInsets = .zero

    public init() {}
}

/// Provides display tasks for a ``LoomAsyncLayer``. `LoomLabel` conforms.
public protocol LoomAsyncLayerDelegate: AnyObject {
    @MainActor func newAsyncDisplayTask() -> LoomAsyncLayerDisplayTask
}

/// A `CALayer` that renders its contents on a background queue with
/// sentinel-based cancellation: every `setNeedsDisplay` (or teardown)
/// bumps the sentinel, invalidating in-flight renders. Stale bitmaps are
/// never committed — the layer always converges on the newest content.
public final class LoomAsyncLayer: CALayer {

    /// Whether rendering happens on a background queue. The synchronous
    /// path renders the same bitmap on the main thread — output is
    /// pixel-identical either way.
    public var displaysAsynchronously = true

    private let sentinel = LoomSentinel()

    /// Hosts the bitmap when a pass has non-zero ink overflow: its
    /// frame extends past the layer bounds so bleeding ink stays
    /// visible. Inserted at index 0 — attachment views and selection
    /// chrome stay above.
    private(set) var inkLayer: CALayer?

    /// Commits a rendered bitmap: to the layer itself for a plain pass,
    /// to the overflow sublayer when ink bleeds; the unused surface is
    /// always cleared.
    @MainActor
    private func commit(image: CGImage?, inkOverflow: UIEdgeInsets) {
        if inkOverflow == .zero {
            contents = image
            inkLayer?.removeFromSuperlayer()
            inkLayer = nil
            return
        }
        contents = nil
        let host: CALayer
        if let inkLayer {
            host = inkLayer
        } else {
            host = CALayer()
            // The bitmap swaps wholesale each pass — implicit fades
            // would smear scrolling content.
            host.actions = [
                "contents": NSNull(), "bounds": NSNull(),
                "position": NSNull(), "hidden": NSNull(),
            ]
            insertSublayer(host, at: 0)
            inkLayer = host
        }
        host.contentsScale = contentsScale
        host.frame = CGRect(
            x: -inkOverflow.left,
            y: -inkOverflow.top,
            width: bounds.width + inkOverflow.left + inkOverflow.right,
            height: bounds.height + inkOverflow.top + inkOverflow.bottom
        )
        host.contents = image
    }

    // MARK: - Render queue pool (YYTextAsyncLayerGetDisplayQueue)

    private static let renderQueues: [DispatchQueue] = {
        let count = max(1, min(16, ProcessInfo.processInfo.activeProcessorCount))
        return (0..<count).map {
            DispatchQueue(label: "com.loomtext.render.\($0)", qos: .userInitiated)
        }
    }()

    private static let queueCounter = LoomSentinel()

    private static func nextRenderQueue() -> DispatchQueue {
        let index = Int(UInt32(bitPattern: queueCounter.increase())) % renderQueues.count
        return renderQueues[index]
    }

    // MARK: - Lifecycle

    public override init() {
        super.init()
        contentsScale = UIScreen.main.scale
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        contentsScale = UIScreen.main.scale
    }

    deinit {
        sentinel.increase()
    }

    // MARK: - Display pipeline

    public override func setNeedsDisplay() {
        sentinel.increase()
        super.setNeedsDisplay()
    }

    public override func display() {
        // CALayer.display() is invoked by Core Animation on the main
        // thread; CALayer itself carries no actor annotation.
        MainActor.assumeIsolated {
            super.contents = super.contents
            displayContent(async: displaysAsynchronously)
        }
    }

    @MainActor
    private func displayContent(async: Bool) {
        guard let delegate = self.delegate as? LoomAsyncLayerDelegate else { return }
        let task = delegate.newAsyncDisplayTask()

        guard let display = task.display, bounds.width >= 1, bounds.height >= 1 else {
            task.willDisplay?(self)
            commit(image: nil, inkOverflow: .zero)
            task.didDisplay?(self, true)
            return
        }

        let overflow = task.inkOverflow
        let size = CGSize(
            width: bounds.width + overflow.left + overflow.right,
            height: bounds.height + overflow.top + overflow.bottom
        )
        let opaque = isOpaque
        let format = UIGraphicsImageRendererFormat()
        format.scale = contentsScale
        format.opaque = opaque
        // CGColor is immutable; boxed only to cross into the render closure.
        let background = (opaque ? backgroundColor : nil).map(UncheckedSendableBox.init)
        // UITraitCollection is immutable; boxed to cross threads.
        let traits = task.traitCollection.map(UncheckedSendableBox.init)

        if async {
            task.willDisplay?(self)
            let sentinel = self.sentinel
            // Increase (not just read): every display pass invalidates all
            // in-flight passes, covering entry paths that bypass our
            // setNeedsDisplay override (e.g. needsDisplayOnBoundsChange) —
            // otherwise two concurrent passes could commit out of order.
            let value = sentinel.increase()
            let isCancelled: @Sendable () -> Bool = { sentinel.value != value }
            // Main-thread-confined values crossing into the render
            // closure; only touched again after hopping back to main.
            let layerBox = UncheckedSendableBox(self)
            let taskBox = UncheckedSendableBox(task)

            Self.nextRenderQueue().async {
                if isCancelled() { return }
                let image = Self.render(
                    size: size, format: format, opaque: opaque, background: background,
                    traits: traits, display: display, isCancelled: isCancelled
                )
                let imageBox = UncheckedSendableBox(image?.cgImage)
                DispatchQueue.main.async {
                    if isCancelled() || imageBox.value == nil {
                        taskBox.value.didDisplay?(layerBox.value, false)
                    } else {
                        layerBox.value.commit(image: imageBox.value, inkOverflow: overflow)
                        taskBox.value.didDisplay?(layerBox.value, true)
                    }
                }
            }
        } else {
            sentinel.increase()
            task.willDisplay?(self)
            let image = Self.render(
                size: size, format: format, opaque: opaque, background: background,
                traits: traits, display: display, isCancelled: { false }
            )
            commit(image: image?.cgImage, inkOverflow: overflow)
            task.didDisplay?(self, true)
        }
    }

    /// Renders one pass into a bitmap. Runs on any thread; dynamic
    /// colors resolve against `traits` when provided.
    private static func render(
        size: CGSize,
        format: UIGraphicsImageRendererFormat,
        opaque: Bool,
        background: UncheckedSendableBox<CGColor>?,
        traits: UncheckedSendableBox<UITraitCollection>?,
        display: (CGContext, CGSize, @escaping @Sendable () -> Bool) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            if opaque {
                context.saveGState()
                if background == nil || background!.value.alpha < 1 {
                    context.setFillColor(UIColor.white.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                }
                if let background {
                    context.setFillColor(background.value)
                    context.fill(CGRect(origin: .zero, size: size))
                }
                context.restoreGState()
            }
            if let traits {
                traits.value.performAsCurrent {
                    display(context, size, isCancelled)
                }
            } else {
                display(context, size, isCancelled)
            }
        }
        return isCancelled() ? nil : image
    }
}
#endif
