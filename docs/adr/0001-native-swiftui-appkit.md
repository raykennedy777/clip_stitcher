# Native macOS app on SwiftUI + AppKit

vid_conform is a native macOS app built with SwiftUI for the app shell and most views,
dropping to AppKit (via `NSViewRepresentable`) only for the custom timeline and the
frame-stepping video view. This was chosen over Electron/web (non-native, fights the HIG,
weak native video, heavyweight) and over pure AppKit (far more verbose, less automatic HIG
behavior) to get Human Interface Guidelines compliance largely for free while staying
readable and maintainable given that the entire codebase is written through Claude Code.
