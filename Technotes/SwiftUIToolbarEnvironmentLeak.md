# SwiftUI Toolbar Environment Leak in NavigationView on macOS 26

## Problem

On macOS 26, when an article's detail column has a dark theme-color background, liquid glass automatically adapts the detail column's toolbar buttons to be visible against the dark background. However, this automatic dark adaptation leaks to toolbar items declared by other columns in the same `NavigationView` — for example, the article list column's filter button also turns white, even though its toolbar area is not dark.

This appears to be a side effect of liquid glass's automatic color scheme handling in the shared `NSToolbar`. In a macOS SwiftUI `NavigationView` with multiple columns (sidebar, list, detail), each column can declare `.toolbar {}` items, but these all get merged into a single shared `NSToolbar` on the window. The liquid glass dark adaptation does not scope itself to the column that has the dark background.

## Reproduction

```swift
// In a three-column NavigationView:

// Column 2 (ArticleListView)
.toolbar {
    Menu { ... } label: {
        Image(systemName: "line.3.horizontal.decrease.circle")
        // ^ This icon unexpectedly turns white on macOS 26
        //   when Column 3 has a dark theme-color background
    }
}

// Column 3 (ArticleView) — has dark theme-color background
// extending behind the toolbar via .edgesIgnoringSafeArea(.all)
.background(Color(themeColor ?? NSColor.textBackgroundColor))
```

No explicit `.environment(\.colorScheme, .dark)` is needed to trigger this — liquid glass on macOS 26 does it automatically based on the dark background behind the toolbar area.

## What Does Not Work

- `.environment(\.colorScheme, systemColorScheme)` on the affected column's toolbar items as a countermeasure — does not override the leak

## Status

As of May 2026, no other reports of this specific issue were found online. Apple's WWDC25 guidance on liquid glass notes that extra backgrounds or darkening effects behind bar items can "interfere with the effect," which may be related. Consider filing via Feedback Assistant.

## References

- [Adopting Liquid Glass (Apple)](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Build a SwiftUI app with the new design - WWDC25](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Glassifying toolbars in SwiftUI (Swift with Majid)](https://swiftwithmajid.com/2025/07/01/glassifying-toolbars-in-swiftui/)
- [FIX Guide to iOS 26 Glass Effect and ToolbarColorScheme Issue](https://pratikpathak.com/fix-guide-to-ios-26-glass-effect-and-toolbarcolorscheme-issue-and-solution/)

## Context

This issue was encountered while implementing Safari-like `<meta name="theme-color">` support for Planet's article detail toolbar. When an article's theme-color is very dark (e.g., `#000`), liquid glass correctly adapts the detail column's toolbar buttons, but also incorrectly adapts the article list column's filter button.
