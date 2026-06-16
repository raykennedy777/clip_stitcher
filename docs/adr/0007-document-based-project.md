# Document-based project model (DocumentGroup)

A project is a macOS document (`.clipstitcher`) managed by SwiftUI's `DocumentGroup`, rather than
a single-window app with hand-rolled save/load. This yields HIG-correct Open / Save / Save As /
Duplicate / Recents / multiple-windows / unsaved-changes tracking essentially for free. The
document stores *references* to source media as security-scoped bookmarks, plus each clip's
in/out range, the target-clip selection, the cached frame index, and the output settings —
never the media itself.
