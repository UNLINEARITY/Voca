# Galaxy implementation snapshot

This document describes the current galaxy implementation for orientation and regression testing. It is not an immutable product specification. A new user request may change the structure, appearance, interaction, or parameter values while retaining required privacy, fallback, and runtime-safety guarantees.

## Current composition

`GalaxyView.sphere(diameter:)` currently layers the following elements from outside to inside:

1. A Metal refraction lens spanning 1.25 times the sphere diameter by default (configurable). Its outer annulus provides dispersion and refraction when screen capture supplies usable frames.
2. A native clear glass ring at the same scale, providing a visible transparent fallback when the Metal path has no content.
3. A frosted core at the sphere diameter, built from material, gradients, highlights, and a rim so the center remains readable without capture permission.
4. A SceneKit word sphere with curved labels, a uniform 25-point logical font baseline at 1× regardless of save count, persisted slider-controlled text scale, automatic rotation, and drag or precise two-finger-scroll inertia.

The tuning panel exposes persisted controls for dispersion, chroma, refraction, rim and fresnel treatment, text scale, sphere/ring scale, core darkening, and rotation direction. Direct rotation (labels follow pointer/finger motion) is the default; the reverse option flips both drag and precise-scroll rotation, and reset restores the default. Pinching or scrolling a phase-less wheel on the sphere adjusts the same text scale; phase-bearing precise scrolls rotate the sphere except while the timeline is open, when scrolling pages through events. Defaults represent the currently accepted preset, not permanent constants.

The top-bar source selector switches between the saved library (the default on every open) and the clipboard's text history without combining their storage. Clipboard image and file history stays in its own window; the galaxy only consumes the watcher's already-filtered text entries. Selecting clipboard text shows its full scrollable content, app and web source, copy time and length, with copy and add-to-library actions. Saved entries keep their symmetric source/save-count labels and scrollable notes; their timeline presents up to six dated events per page on paired arcs, with wheel/trackpad paging and on-screen page controls. The selected word retains the regular texture and color, enlarges slightly, and lifts outward from the sphere while other words recede.

## Required regression properties

When changing the galaxy, verify that:

- It remains visible and usable when ScreenCaptureKit returns no displays or frames.
- Closing the window does not remove an active event monitor from inside its callback.
- The fullscreen hosting arrangement retains the intended window frame.
- Launching with `--galaxy` opens the galaxy in a newly launched instance.
- Interaction remains responsive at realistic library sizes.
- Persisted user settings either remain compatible or receive an explicit migration/reset policy.

## Known platform issue

ScreenCaptureKit can fail to provide usable frames despite an apparent Screen Recording grant. Capture now starts after the window becomes visible and retries transient first-frame failures; the native ring and frosted core still preserve the experience if capture remains unavailable. Keep this fallback even if the capture path changes.
