import Foundation
import AppKit

struct ThemeColorExtractor {

    struct Entry {
        let color: String
        let prefersColorScheme: String?  // "dark", "light", or nil
    }

    // MARK: - Public API

    /// Extract the resolved NSColor from a local HTML file for the current appearance.
    static func extractColor(from fileURL: URL, appearance: NSAppearance? = nil) -> NSColor? {
        guard fileURL.isFileURL else { return nil }
        guard let data = readHead(of: fileURL, maxBytes: 4096),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        let entries = extractEntries(from: html)
        return resolveColor(entries: entries, appearance: appearance)
    }

    /// Parse all `<meta name="theme-color">` entries from an HTML string.
    static func extractEntries(from html: String) -> [Entry] {
        // Pattern matches <meta name="theme-color" content="..." media="...">
        // Handles single/double quotes and optional media attribute in any order.
        let pattern = #"<meta\s[^>]*name\s*=\s*["']theme-color["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        var entries: [Entry] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: html) else { continue }
            let tag = String(html[matchRange])

            guard let color = extractAttribute("content", from: tag) else { continue }
            let media = extractAttribute("media", from: tag)
            let scheme = parsePrefersColorScheme(from: media)
            entries.append(Entry(color: color, prefersColorScheme: scheme))
        }
        return entries
    }

    /// Resolve the best matching color for the given appearance.
    static func resolveColor(entries: [Entry], appearance: NSAppearance? = nil) -> NSColor? {
        guard !entries.isEmpty else { return nil }

        let isDark: Bool
        if let appearance = appearance {
            isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        } else {
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        let preferred = isDark ? "dark" : "light"

        // First: exact match for current scheme
        if let entry = entries.first(where: { $0.prefersColorScheme == preferred }) {
            return parseColor(entry.color)
        }
        // Second: entry with no media query (generic)
        if let entry = entries.first(where: { $0.prefersColorScheme == nil }) {
            return parseColor(entry.color)
        }
        // Last resort: first entry
        return parseColor(entries[0].color)
    }

    /// Parse a CSS color string into NSColor.
    /// Supports hex (#rgb, #rrggbb, #rrggbbaa) and rgb()/rgba() notation.
    static func parseColor(_ colorString: String) -> NSColor? {
        let trimmed = colorString.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("#") {
            return parseHexColor(trimmed)
        }
        if trimmed.hasPrefix("rgb") {
            return parseRGBColor(trimmed)
        }
        return nil
    }

    private static func parseHexColor(_ hex: String) -> NSColor? {
        let hex = String(hex.dropFirst())
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }

        let r, g, b: CGFloat
        switch hex.count {
        case 3:
            r = CGFloat((int >> 8) & 0xF) / 15.0
            g = CGFloat((int >> 4) & 0xF) / 15.0
            b = CGFloat(int & 0xF) / 15.0
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255.0
            g = CGFloat((int >> 8) & 0xFF) / 255.0
            b = CGFloat(int & 0xFF) / 255.0
        case 8:
            r = CGFloat((int >> 24) & 0xFF) / 255.0
            g = CGFloat((int >> 16) & 0xFF) / 255.0
            b = CGFloat((int >> 8) & 0xFF) / 255.0
        default:
            return nil
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Parse "rgb(r, g, b)" or "rgba(r, g, b, a)" into NSColor.
    private static func parseRGBColor(_ str: String) -> NSColor? {
        // Extract the numbers between parentheses
        guard let open = str.firstIndex(of: "("),
              let close = str.firstIndex(of: ")")
        else { return nil }

        let inner = str[str.index(after: open)..<close]
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 3,
              let ri = Double(parts[0]),
              let gi = Double(parts[1]),
              let bi = Double(parts[2])
        else { return nil }

        let r = CGFloat(ri / 255.0)
        let g = CGFloat(gi / 255.0)
        let b = CGFloat(bi / 255.0)

        // Filter out near-white backgrounds — they're the page default and
        // shouldn't override the system text background color.
        if r > 0.95 && g > 0.95 && b > 0.95 { return nil }

        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Returns true if the color's perceived luminance is dark.
    static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance < 0.5
    }

    // MARK: - Private Helpers

    private static func readHead(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        return handle.readData(ofLength: maxBytes)
    }

    private static func extractAttribute(_ name: String, from tag: String) -> String? {
        // Match attribute="value" or attribute='value'
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let valueRange = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[valueRange])
    }

    private static func parsePrefersColorScheme(from media: String?) -> String? {
        guard let media = media else { return nil }
        // Extract "dark" or "light" from media="(prefers-color-scheme: dark)"
        if media.contains("dark") { return "dark" }
        if media.contains("light") { return "light" }
        return nil
    }

    #if DEBUG
    private static let logURL: URL = {
        let tmp = FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent("planet-theme-debug.log")
    }()

    static func debugLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
    #endif
}
