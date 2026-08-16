import AppKit

/// Default curve colors, cycled by index -- chosen to match the look of the DGCharts-based charts
/// this framework replaced (DGCharts' own "colorful" template plus its default single-series blue),
/// purely so replacing the library didn't also change how existing results looked.
enum ChartPalette {
    static let colors: [NSColor] = [
        NSColor(red: 193 / 255, green: 37 / 255, blue: 82 / 255, alpha: 1),
        NSColor(red: 255 / 255, green: 102 / 255, blue: 0 / 255, alpha: 1),
        NSColor(red: 245 / 255, green: 199 / 255, blue: 0 / 255, alpha: 1),
        NSColor(red: 106 / 255, green: 150 / 255, blue: 31 / 255, alpha: 1),
        NSColor(red: 179 / 255, green: 100 / 255, blue: 53 / 255, alpha: 1),
        NSColor(red: 140 / 255, green: 234 / 255, blue: 255 / 255, alpha: 1),
    ]
}
