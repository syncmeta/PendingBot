# Todo #30: sidebar privacy control

The message sidebar toolbar now starts with the privacy eye button, before
search and the existing menus. It uses the same persisted manual setting as
the window shell. The reveal button explicitly stays enabled while covered.

The privacy effect is only the existing radius-24 blur. The canvas overlay and
the centered label have been removed. Background activation and the scope of
the message page are unchanged.

Validation: macOS and iOS Simulator builds, with signing disabled. Interactive
QA remains required on the signed package: button position, toggle on/off,
background/foreground transitions, and absence of tint or text over the blur.
Compilation and notarization do not prove those visual checks.
