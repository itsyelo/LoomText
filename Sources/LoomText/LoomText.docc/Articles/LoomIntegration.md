# Using LoomText with Loom

Wire the two sister libraries so measurement and rendering are the same pass.

## Overview

LoomText has no dependency on [Loom](https://github.com/itsyelo/Loom);
the integration is a small bridge you own. Two patterns, both keeping
"typeset once" true:

## Pattern 1 — measure through LoomText

Conform Loom's `TextMeasuring` to route text measurement through
``LoomTextLayout``:

```swift
struct LoomTextMeasurer: TextMeasuring {
    func measure(_ text: NSAttributedString, maxWidth: CGFloat,
                 maxHeight: CGFloat, maxLines: Int) -> CGSize {
        let container = LoomTextContainer(
            size: CGSize(width: maxWidth, height: maxHeight),
            maximumNumberOfRows: maxLines
        )
        return LoomTextLayout(container: container, text: text)?
            .textBoundingSize ?? .zero
    }
}
```

## Pattern 2 — prebuilt layout as a Loom node

When the view model already owns the ``LoomTextLayout``, hand Loom its
exact size and give ``LoomLabel`` the same instance:

```swift
func LTText(_ layout: LoomTextLayout) -> LoomNode {
    Measured { _, _ in layout.textBoundingSize }
}
```

The `Example/LoomTextExample` app's **Loom Feed** and **Chat** tabs run
entirely on this pattern: view models build layouts in a chunked
background pipeline, cells assign frames and layouts without measuring
anything on the main thread.
