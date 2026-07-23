import AppKit

/// Static menu bar fan icon. Color tracks average CPU temperature; no animation.
final class MenuBarFanIcon {
    private weak var button: NSStatusBarButton?
    private var baseSymbol: NSImage?
    private var currentTint: NSColor = .secondaryLabelColor

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.title = ""
        button.imagePosition = .imageOnly

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        baseSymbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "Fan")?
            .withSymbolConfiguration(config)

        apply(color: currentTint)
    }

    /// `cpuTempC` — average CPU temperature in °C.
    func update(cpuTempC: Double, loading: Bool) {
        let color: NSColor
        if loading {
            color = NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.85, alpha: 1)
        } else if cpuTempC <= 0 {
            color = NSColor(calibratedWhite: 0.35, alpha: 1)
        } else if cpuTempC < 45 {
            color = NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.78, alpha: 1)   // deep blue
        } else if cpuTempC < 60 {
            color = NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.22, alpha: 1)   // deep green
        } else if cpuTempC < 75 {
            color = NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.05, alpha: 1)   // deep gold
        } else if cpuTempC < 90 {
            color = NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.05, alpha: 1)   // deep orange
        } else {
            color = NSColor(calibratedRed: 0.75, green: 0.10, blue: 0.10, alpha: 1)   // deep red
        }
        apply(color: color)
    }

    private func apply(color: NSColor) {
        guard let button, let baseSymbol else { return }

        var or = CGFloat(0), og = CGFloat(0), ob = CGFloat(0), oa = CGFloat(0)
        var nr = CGFloat(0), ng = CGFloat(0), nb = CGFloat(0), na = CGFloat(0)
        currentTint.usingColorSpace(.sRGB)?.getRed(&or, green: &og, blue: &ob, alpha: &oa)
        color.usingColorSpace(.sRGB)?.getRed(&nr, green: &ng, blue: &nb, alpha: &na)
        if abs(or - nr) < 0.01 && abs(og - ng) < 0.01 && abs(ob - nb) < 0.01 {
            return
        }
        currentTint = color

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
}
