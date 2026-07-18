# Async Rendering

How LoomLabel keeps the main thread idle while text rasterizes.

## The pipeline

With `displaysAsynchronously = true`, ``LoomLabel`` backs itself with
``LoomAsyncLayer``. Each display pass:

1. Captures a ``LoomAsyncLayerDisplayTask`` snapshot of everything the
   render needs (layout, colors, traits) on the main thread.
2. Rasterizes on a pooled serial background queue via
   `UIGraphicsImageRenderer`, polling a cancellation sentinel between
   lines and attachments.
3. Commits the bitmap to `layer.contents` back on the main thread.

Commits are coalesced through a run-loop transaction (one flush per
tick, `CFRunLoopObserver` at commit time), so a burst of invalidations
costs one render.

## Cancellation

Every new display pass increments the layer's sentinel; in-flight
renders observe the bump and abort at the next polling point. Stale
bitmaps are never committed — a fast scroll never paints yesterday's
cell content.

## Dynamic colors

The display task carries the label's `UITraitCollection` and renders
inside `performAsCurrent`, so dynamic colors resolve correctly off the
main thread. Trait changes (dark mode) invalidate and re-render
automatically.

> Important: A custom `UIColor(dynamicProvider:)` is *resolved on the
> render thread*. Under Swift 6, a provider closure created in a
> `@MainActor` context is inferred MainActor-isolated and traps when
> the async pipeline resolves it — mark it `@Sendable`:
> `UIColor { @Sendable traits in … }`. System dynamic colors
> (`.label`, `.systemBackground`, …) are unaffected.

## Attachments

Image-content attachments draw into the bitmap. View and layer content
is mounted on the main thread after the bitmap commits — see
``LoomTextAttachment`` and its `viewProvider` / `onViewUnmounted`
hooks for pool-backed animated content.
