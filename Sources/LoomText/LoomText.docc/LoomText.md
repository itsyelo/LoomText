# ``LoomText``

CoreText text rendering with precomputed layout and asynchronous drawing.

## Overview

LoomText splits text display into two halves that never disagree:

- ``LoomTextLayout`` typesets an attributed string against a
  ``LoomTextContainer`` into an immutable, thread-safe result. Build it
  on any thread; read `textBoundingSize` to size cells.
- ``LoomLabel`` renders a prebuilt layout — synchronously in
  `draw(_:)`-less direct mode, or asynchronously on a background queue
  with sentinel cancellation and run-loop-coalesced commits.

Because measurement and rendering read the same object, there is no
double typesetting and no cross-engine alignment residual.

## Topics

### Building a layout

- ``LoomTextContainer``
- ``LoomTextLayout``
- ``LoomTextLine``
- ``LoomTextTruncationType``

### Rendering

- ``LoomLabel``
- ``LoomAsyncLayer``
- ``LoomAsyncLayerDelegate``
- ``LoomAsyncLayerDisplayTask``

### Interaction and decoration

- ``LoomTextHighlight``
- ``LoomTextBackground``
- ``LoomTextSelectionInitialRange``

### Attachments

- ``LoomTextAttachment``
- ``LoomTextVerticalAlignment``

### Articles

- <doc:GettingStarted>
- <doc:AsyncRendering>
- <doc:TextSelection>
- <doc:LoomIntegration>
