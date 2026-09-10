import AppKit

/// Menu bar fan glyph, optionally with a live readout beside it.
/// Colour tracks average CPU temperature; no animation.
@MainActor
final class MenuBarFanIcon {
    private weak var button: NSStatusBarButton?
    private var baseSymbol: NSImage?
    private var currentTint: NSColor = .secondaryLabelColor
    private var currentText: String = ""

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.title = ""
        button.imagePosition = .imageOnly

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        baseSymbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "Fan")?
            .withSymbolConfiguration(config)

        apply(color: currentTint, force: true)
    }

    /// `cpuTempC` — average CPU temperature in °C, used for the tint regardless of
    /// which readout is displayed. `text` is nil in icon-only mode.
    func update(cpuTempC: Double, loading: Bool, text: String?) {
        apply(color: Self.tint(forTemperature: cpuTempC, loading: loading), text: text ?? "")
    }

    private static func tint(forTemperature cpuTempC: Double, loading: Bool) -> NSColor {
        if loading { return NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.85, alpha: 1) }
        switch cpuTempC {
        case ..<35:  return NSColor(calibratedWhite: 0.35, alpha: 1)                       // unknown / idle
        case ..<56:  return NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.22, alpha: 1) // green
        case ..<75:  return NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.05, alpha: 1) // yellow
        case ..<90:  return NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.05, alpha: 1) // orange
        default:     return NSColor(calibratedRed: 0.75, green: 0.10, blue: 0.10, alpha: 1) // red
        }
    }

    private func apply(color: NSColor, text: String = "", force: Bool = false) {
        guard let button, let baseSymbol else { return }

        let textChanged = text != currentText
        var colorChanged = force
        if !colorChanged {
            var or = CGFloat(0), og = CGFloat(0), ob = CGFloat(0), oa = CGFloat(0)
            var nr = CGFloat(0), ng = CGFloat(0), nb = CGFloat(0), na = CGFloat(0)
            currentTint.usingColorSpace(.sRGB)?.getRed(&or, green: &og, blue: &ob, alpha: &oa)
            color.usingColorSpace(.sRGB)?.getRed(&nr, green: &ng, blue: &nb, alpha: &na)
            colorChanged = abs(or - nr) >= 0.01 || abs(og - ng) >= 0.01 || abs(ob - nb) >= 0.01
        }
        // Redrawing the status item is not free; skip when nothing visible changed.
        guard textChanged || colorChanged else { return }

        currentTint = color
        currentText = text

        if colorChanged || force {
            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                baseSymbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            image.isTemplate = false
            button.image = image
        }

        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.imagePosition = .imageLeading
            // Monospaced digits stop the status item resizing as values change.
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
        }
    }
}
