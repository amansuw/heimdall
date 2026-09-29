import SwiftUI
import AppKit

// MARK: - Chart Insets (room for axis labels)

/// Axis label font. The gutter is measured with the same size.
private let axisLabelSize: CGFloat = 9
/// Space between a y label and the plot.
private let axisLabelGap: CGFloat = 4
private let chartBottomPad: CGFloat = 20
/// Room above the top gridline for its label, so every label sits centred on
/// its gridline instead of the end ones being nudged inward.
private let chartTopPad: CGFloat = 6

/// Plot height of every history chart in the main window.
let historyChartHeight: CGFloat = 170

/// Y for a value's fraction of the scale. `plotBottom` is the x-axis line.
private func plotY(_ frac: Double, plotBottom: CGFloat) -> CGFloat {
    let clamped = CGFloat(Swift.min(Swift.max(frac, 0), 1))
    return plotBottom - clamped * (plotBottom - chartTopPad)
}

// MARK: - Samples & Time Domain

/// A single plotted sample. `value == nil` means the sample is MISSING
/// (sensor unavailable for that tick) and the line is broken across it.
struct ChartPoint: Equatable {
    let time: Date
    let value: Double?

    init(time: Date, value: Double?) {
        self.time = time
        if let value, value.isFinite {
            self.value = value
        } else {
            self.value = nil
        }
    }
}

/// The wall-clock x-domain a chart is drawn against: `[end - window, end]`.
/// Every series in a chart shares one domain, so series of differing
/// lengths / cadences stay aligned in time.
struct ChartTimeDomain: Equatable {
    let start: Date
    let end: Date
    /// Width of the y-label gutter left of the plot, sized to this chart's
    /// widest label so short labels ("80°") do not leave a wide empty margin.
    let leftPad: CGFloat

    var span: TimeInterval { max(end.timeIntervalSince(start), 1) }

    init(end: Date, window: TimeInterval, leftPad: CGFloat) {
        self.end = end
        self.start = end.addingTimeInterval(-max(window, 1))
        self.leftPad = leftPad
    }

    func x(for time: Date, plotW: CGFloat) -> CGFloat {
        let frac = time.timeIntervalSince(start) / span
        return leftPad + CGFloat(min(max(frac, 0), 1)) * plotW
    }

    /// Like `x(for:)` but not pinned to the plot. The sample just before the
    /// window lands left of the plot, so the line enters at the right slope
    /// and the canvas clip trims it.
    func unclampedX(for time: Date, plotW: CGFloat) -> CGFloat {
        leftPad + CGFloat(time.timeIntervalSince(start) / span) * plotW
    }

    func time(atX x: CGFloat, plotW: CGFloat) -> Date {
        guard plotW > 0 else { return end }
        let frac = Double((x - leftPad) / plotW)
        return start.addingTimeInterval(min(max(frac, 0), 1) * span)
    }
}

/// Builds the shared domain for a set of series: `[latest - window, latest]`.
/// The right edge is the last sample, not wall-clock `Date()`. Hover used to
/// call `Date()` on its own Canvas while the plot stayed frozen, so the dots
/// sat to the left of the lines.
private func makeDomain(_ pointSets: [[ChartPoint]], window: TimeInterval,
                        scale: ChartYScale, yFormatter: (Double) -> String) -> ChartTimeDomain {
    let latest = pointSets.compactMap { $0.last?.time }.max() ?? Date()
    return ChartTimeDomain(end: latest, window: window, leftPad: yAxisGutter(scale: scale, formatter: yFormatter))
}

/// The widest tick label plus the gap to the plot, and a 2pt margin on the
/// view's leading edge.
private func yAxisGutter(scale: ChartYScale, formatter: (Double) -> String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: axisLabelSize)
    let widest = scale.ticks.map { label in
        (formatter(label) as NSString).size(withAttributes: [.font: font]).width
    }.max() ?? 0
    return ceil(widest) + axisLabelGap + 2
}

// MARK: - Axis Helpers

/// Rounds a span to a "nice" 1 / 2 / 5 / 10 multiple of a power of ten.
private func niceNumber(_ value: Double, roundToNearest: Bool) -> Double {
    guard value > 0, value.isFinite else { return 1 }
    let exponent = floor(log10(value))
    let fraction = value / pow(10, exponent)
    let nice: Double
    if roundToNearest {
        if fraction < 1.5 { nice = 1 }
        else if fraction < 3 { nice = 2 }
        else if fraction < 7 { nice = 5 }
        else { nice = 10 }
    } else {
        if fraction <= 1 { nice = 1 }
        else if fraction <= 2 { nice = 2 }
        else if fraction <= 5 { nice = 5 }
        else { nice = 10 }
    }
    return nice * pow(10, exponent)
}

struct ChartYScale: Equatable {
    let min: Double
    let max: Double
    let step: Double

    var range: Double { Swift.max(max - min, .leastNonzeroMagnitude) }

    var ticks: [Double] {
        guard step > 0 else { return [min, max] }
        let count = Swift.min(Int(((max - min) / step).rounded()), 12)
        guard count >= 1 else { return [min, max] }
        return (0...count).map { min + Double($0) * step }
    }
}

/// Picks rounded tick values instead of raw data-derived ones.
private func niceYScale(min lo: Double, max hi: Double, targetSteps: Int = 4) -> ChartYScale {
    var low = lo.isFinite ? lo : 0
    var high = hi.isFinite ? hi : 1
    if high < low { swap(&low, &high) }
    if high - low <= 0 {
        let pad = Swift.max(abs(high) * 0.1, 1)
        low -= pad
        high += pad
    }
    let step = niceNumber((high - low) / Double(targetSteps), roundToNearest: true)
    guard step > 0, step.isFinite else { return ChartYScale(min: low, max: high, step: high - low) }
    var niceMin = (low / step).rounded(.down) * step
    var niceMax = (high / step).rounded(.up) * step
    // Never invent negative ticks (byte rates, percentages) for non-negative data.
    if lo >= 0 && niceMin < 0 { niceMin = 0 }
    if niceMax <= niceMin { niceMax = niceMin + step }
    return ChartYScale(min: niceMin, max: niceMax, step: step)
}

private func drawYAxis(
    _ context: GraphicsContext,
    size: CGSize,
    scale: ChartYScale,
    leftPad: CGFloat,
    formatter: (Double) -> String
) {
    let plotH = size.height - chartBottomPad
    guard plotH > 0, scale.range > 0 else { return }
    let ticks = scale.ticks
    for (i, val) in ticks.enumerated() {
        let frac = (val - scale.min) / scale.range
        let y = plotY(frac, plotBottom: plotH)
        var gridPath = Path()
        gridPath.move(to: CGPoint(x: leftPad, y: y))
        gridPath.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(gridPath, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

        let label = Text(formatter(val)).font(.system(size: axisLabelSize)).foregroundColor(.secondary)
        context.draw(context.resolve(label), at: CGPoint(x: leftPad - axisLabelGap, y: y), anchor: .trailing)
    }
}

// MARK: - X Axis (wall-clock)

private let clockMinuteFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
}()

private let clockSecondFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// Tick granularity per history range (1m / 5m / 30m / 60m).
private func xTickInterval(for window: TimeInterval) -> TimeInterval {
    switch window {
    case ..<120: return 15      // 1m  -> every 15s
    case ..<900: return 60      // 5m  -> every minute
    case ..<2400: return 300    // 30m -> every 5 minutes
    default: return 600         // 60m -> every 10 minutes
    }
}

private func drawXAxisTimes(
    _ context: GraphicsContext,
    size: CGSize,
    domain: ChartTimeDomain,
    window: TimeInterval
) {
    let plotW = size.width - domain.leftPad
    let plotH = size.height - chartBottomPad
    guard plotW > 8, plotH > 0 else { return }

    let interval = xTickInterval(for: window)
    let formatter = interval < 60 ? clockSecondFormatter : clockMinuteFormatter
    // Align ticks to local wall-clock boundaries, not to the UTC epoch.
    let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: domain.end))
    let startEpoch = domain.start.timeIntervalSince1970 + tzOffset
    let endEpoch = domain.end.timeIntervalSince1970 + tzOffset
    var tick = (startEpoch / interval).rounded(.up) * interval

    var emitted = 0
    while tick <= endEpoch && emitted < 32 {
        emitted += 1
        let date = Date(timeIntervalSince1970: tick - tzOffset)
        let x = domain.x(for: date, plotW: plotW)

        var tickPath = Path()
        tickPath.move(to: CGPoint(x: x, y: plotH))
        tickPath.addLine(to: CGPoint(x: x, y: plotH + 3))
        context.stroke(tickPath, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)

        // Keep the first/last labels inside the plot instead of clipping them.
        let anchor: UnitPoint
        if x - domain.leftPad < 16 { anchor = .leading }
        else if size.width - x < 16 { anchor = .trailing }
        else { anchor = .center }

        let label = Text(formatter.string(from: date)).font(.system(size: 8)).foregroundColor(.secondary)
        context.draw(context.resolve(label), at: CGPoint(x: x, y: plotH + 10), anchor: anchor)

        tick += interval
    }
}

// MARK: - Geometry Helpers

/// Splits a series into contiguous runs of present samples so the line breaks
/// across MISSING samples instead of dropping to zero.
private func chartSegments(
    points: [ChartPoint],
    domain: ChartTimeDomain,
    scale: ChartYScale,
    plotW: CGFloat,
    plotH: CGFloat
) -> [[CGPoint]] {
    var segments: [[CGPoint]] = []
    var current: [CGPoint] = []
    for point in points {
        guard let value = point.value else {
            if !current.isEmpty { segments.append(current); current = [] }
            continue
        }
        let x = domain.unclampedX(for: point.time, plotW: plotW)
        let frac = (value - scale.min) / scale.range
        let y = plotY(frac, plotBottom: plotH)
        current.append(CGPoint(x: x, y: y))
    }
    if !current.isEmpty { segments.append(current) }
    return segments
}

/// The plot area, with a little headroom so a 1.5pt line on the top or
/// bottom gridline is not shaved in half.
private func plotClipRect(size: CGSize, leftPad: CGFloat) -> CGRect {
    CGRect(x: leftPad, y: -2, width: size.width - leftPad, height: size.height - chartBottomPad + 4)
}

private func strokeSegments(
    _ segments: [[CGPoint]],
    in context: GraphicsContext,
    color: Color,
    style: StrokeStyle
) {
    var path = Path()
    for segment in segments {
        guard let first = segment.first else { continue }
        if segment.count == 1 {
            // Isolated sample between gaps: draw a dot so it is not invisible.
            let dot = Path(ellipseIn: CGRect(x: first.x - 1.25, y: first.y - 1.25, width: 2.5, height: 2.5))
            context.fill(dot, with: .color(color))
            continue
        }
        path.move(to: first)
        for point in segment.dropFirst() { path.addLine(to: point) }
    }
    if !path.isEmpty {
        context.stroke(path, with: .color(color), style: style)
    }
}

private func valueBounds(_ pointSets: [[ChartPoint]]) -> (min: Double, max: Double)? {
    var lo = Double.infinity
    var hi = -Double.infinity
    for set in pointSets {
        for point in set {
            guard let value = point.value else { continue }
            lo = Swift.min(lo, value)
            hi = Swift.max(hi, value)
        }
    }
    guard lo.isFinite, hi.isFinite else { return nil }
    return (lo, hi)
}

private func presentCount(_ points: [ChartPoint]) -> Int {
    points.reduce(0) { $1.value != nil ? $0 + 1 : $0 }
}

/// Index of the sample nearest `time` that actually has a value.
private func nearestIndex(in points: [ChartPoint], to time: Date) -> Int? {
    var best: Int?
    var bestDelta = Double.infinity
    for (i, point) in points.enumerated() {
        guard point.value != nil else { continue }
        let delta = abs(point.time.timeIntervalSince(time))
        if delta < bestDelta { bestDelta = delta; best = i }
    }
    return best
}

// MARK: - Semantic Chart Colors (work in light & dark)

private let crosshairColor = Color.primary.opacity(0.35)
private let dotOutlineColor = Color(nsColor: .controlBackgroundColor)

// MARK: - Hover State

@MainActor
@Observable
class ChartHoverState {
    var hoverX: CGFloat? = nil
}

// MARK: - Plot / Crosshair (kept on separate Canvases)

/// Hover used to live inside the same Canvas as the series. On macOS that
/// makes Observation re-run the draw with an empty capture, so the lines
/// vanish until the next poll. The plot Canvas never reads hover state.

private func chartYScale(for pointSets: [[ChartPoint]], yRange: ClosedRange<Double>?,
                         binary: Bool = false) -> ChartYScale {
    if let yRange {
        return niceYScale(min: yRange.lowerBound, max: yRange.upperBound)
    }
    let bounds = valueBounds(pointSets) ?? (0, 100)
    guard binary else { return niceYScale(min: bounds.min, max: bounds.max) }
    // Byte rates are shown in 1024-based units, so pick round steps in those
    // units: 0.5 / 1 / 1.5 MB/s rather than 488.3 / 976.6 KB/s.
    let unit = bounds.max >= 1024 ? pow(1024, floor(log(bounds.max) / log(1024))) : 1
    let scaled = niceYScale(min: bounds.min / unit, max: bounds.max / unit)
    return ChartYScale(min: scaled.min * unit, max: scaled.max * unit, step: scaled.step * unit)
}

@MainActor
private func updateHover(_ hoverState: ChartHoverState, x: CGFloat?) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        hoverState.hoverX = x
    }
}

private struct LinePlotCanvas: View {
    let points: [ChartPoint]
    let domain: ChartTimeDomain
    let scale: ChartYScale
    let window: TimeInterval
    let color: Color
    let fillColor: Color?
    let lineWidth: CGFloat
    let yFormatter: (Double) -> String

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard presentCount(points) >= 1 else { return }
            let plotW = size.width - domain.leftPad
            let plotH = size.height - chartBottomPad
            guard plotW > 0, plotH > 0 else { return }

            drawYAxis(context, size: size, scale: scale, leftPad: domain.leftPad, formatter: yFormatter)
            drawXAxisTimes(context, size: size, domain: domain, window: window)

            var context = context
            context.clip(to: Path(plotClipRect(size: size, leftPad: domain.leftPad)))
            let segments = chartSegments(points: points, domain: domain, scale: scale, plotW: plotW, plotH: plotH)
            if let fillColor {
                for segment in segments where segment.count >= 2 {
                    var fillPath = Path()
                    fillPath.move(to: CGPoint(x: segment[0].x, y: plotH))
                    for point in segment { fillPath.addLine(to: point) }
                    fillPath.addLine(to: CGPoint(x: segment[segment.count - 1].x, y: plotH))
                    fillPath.closeSubpath()
                    context.fill(fillPath, with: .color(fillColor))
                }
            }
            strokeSegments(segments, in: context, color: color, style: StrokeStyle(lineWidth: lineWidth))
        }
    }
}

private struct LineCrosshairCanvas: View {
    let points: [ChartPoint]
    let domain: ChartTimeDomain
    let scale: ChartYScale
    let color: Color
    let hoverX: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let plotW = size.width - domain.leftPad
            let plotH = size.height - chartBottomPad
            guard plotW > 0, plotH > 0, hoverX >= domain.leftPad, hoverX <= size.width else { return }
            let hoverTime = domain.time(atX: hoverX, plotW: plotW)
            guard let idx = nearestIndex(in: points, to: hoverTime), let val = points[idx].value else { return }
            let snapX = domain.x(for: points[idx].time, plotW: plotW)
            let frac = (val - scale.min) / scale.range
            let snapY = plotY(frac, plotBottom: plotH)

            var vLine = Path()
            vLine.move(to: CGPoint(x: snapX, y: 0))
            vLine.addLine(to: CGPoint(x: snapX, y: plotH))
            context.stroke(vLine, with: .color(crosshairColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            let dot = Path(ellipseIn: CGRect(x: snapX - 4, y: snapY - 4, width: 8, height: 8))
            context.fill(dot, with: .color(color))
            context.stroke(dot, with: .color(dotOutlineColor), lineWidth: 1.5)
        }
    }
}

private struct MultiLinePlotCanvas: View {
    let series: [CanvasMultiLineChart.Series]
    let domain: ChartTimeDomain
    let scale: ChartYScale
    let window: TimeInterval
    let yFormatter: (Double) -> String

    var body: some View {
        let pointSets = series.map(\.points)
        Canvas(rendersAsynchronously: false) { context, size in
            guard pointSets.contains(where: { presentCount($0) >= 1 }) else { return }
            let plotW = size.width - domain.leftPad
            let plotH = size.height - chartBottomPad
            guard plotW > 0, plotH > 0 else { return }

            drawYAxis(context, size: size, scale: scale, leftPad: domain.leftPad, formatter: yFormatter)
            drawXAxisTimes(context, size: size, domain: domain, window: window)

            var context = context
            context.clip(to: Path(plotClipRect(size: size, leftPad: domain.leftPad)))
            for s in series {
                let segments = chartSegments(points: s.points, domain: domain, scale: scale, plotW: plotW, plotH: plotH)
                let style: StrokeStyle = s.dashed
                    ? StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    : StrokeStyle(lineWidth: 1.5)
                if let fill = s.fillColor {
                    for segment in segments where segment.count >= 2 {
                        var area = Path()
                        area.move(to: CGPoint(x: segment[0].x, y: plotH))
                        for point in segment { area.addLine(to: point) }
                        area.addLine(to: CGPoint(x: segment[segment.count - 1].x, y: plotH))
                        area.closeSubpath()
                        context.fill(area, with: .color(fill))
                    }
                }
                strokeSegments(segments, in: context, color: s.color, style: style)
            }
        }
    }
}

private struct MultiLineCrosshairCanvas: View {
    let series: [CanvasMultiLineChart.Series]
    let domain: ChartTimeDomain
    let scale: ChartYScale
    let hoverX: CGFloat

    var body: some View {
        let reference = series.max { presentCount($0.points) < presentCount($1.points) }
        Canvas(rendersAsynchronously: false) { context, size in
            let plotW = size.width - domain.leftPad
            let plotH = size.height - chartBottomPad
            guard plotW > 0, plotH > 0, hoverX >= domain.leftPad, hoverX <= size.width,
                  let reference else { return }
            guard let refIdx = nearestIndex(in: reference.points, to: domain.time(atX: hoverX, plotW: plotW)) else { return }
            let snapTime = reference.points[refIdx].time
            let snapX = domain.x(for: snapTime, plotW: plotW)

            var vLine = Path()
            vLine.move(to: CGPoint(x: snapX, y: 0))
            vLine.addLine(to: CGPoint(x: snapX, y: plotH))
            context.stroke(vLine, with: .color(crosshairColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            for s in series {
                guard let idx = nearestIndex(in: s.points, to: snapTime),
                      let val = s.points[idx].value else { continue }
                let x = domain.x(for: s.points[idx].time, plotW: plotW)
                let frac = (val - scale.min) / scale.range
                let y = plotY(frac, plotBottom: plotH)
                let dot = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(s.color))
                context.stroke(dot, with: .color(dotOutlineColor), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Hover Tooltip

private struct ChartTooltip: View {
    let header: String?
    /// (color, label, value, dashed)
    let values: [(Color, String, String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let header {
                Text(header)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    ChartLineSwatch(color: item.0, dashed: item.3)
                    Text(item.1).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(item.2).font(.system(size: 9, weight: .medium, design: .rounded))
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Mini solid or dashed line sample for legends / tooltips.
struct ChartLineSwatch: View {
    let color: Color
    var dashed: Bool = false

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let y = size.height / 2
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let style: StrokeStyle = dashed
                ? StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 2])
                : StrokeStyle(lineWidth: 2, lineCap: .round)
            context.stroke(path, with: .color(color), style: style)
        }
        .frame(width: 14, height: 6)
    }
}

// MARK: - Single Line Chart

/// High-performance chart using SwiftUI Canvas (Core Graphics context).
/// Plots against wall-clock time over a fixed `[end - window, end]` domain, so
/// new samples scroll the line left instead of compressing the whole series.
struct CanvasLineChart: View {
    let points: [ChartPoint]
    let window: TimeInterval
    let color: Color
    let fillColor: Color?
    let lineWidth: CGFloat
    let yRange: ClosedRange<Double>?
    let label: String
    let yFormatter: (Double) -> String
    let tooltipFormatter: (Double) -> String

    @State private var hoverState = ChartHoverState()

    init(
        points: [ChartPoint],
        window: TimeInterval,
        color: Color = .blue,
        fillColor: Color? = nil,
        lineWidth: CGFloat = 1.5,
        yRange: ClosedRange<Double>? = nil,
        label: String = "Value",
        yFormatter: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        tooltipFormatter: @escaping (Double) -> String = { String(format: "%.1f", $0) }
    ) {
        self.points = points
        self.window = window
        self.color = color
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.yRange = yRange
        self.label = label
        self.yFormatter = yFormatter
        self.tooltipFormatter = tooltipFormatter
    }

    /// Convenience: build from any timestamped snapshot array.
    init<T: TimestampedSample>(
        _ samples: [T],
        window: TimeInterval,
        value: (T) -> Double?,
        color: Color = .blue,
        fillColor: Color? = nil,
        lineWidth: CGFloat = 1.5,
        yRange: ClosedRange<Double>? = nil,
        label: String = "Value",
        yFormatter: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        tooltipFormatter: @escaping (Double) -> String = { String(format: "%.1f", $0) }
    ) {
        self.init(
            points: samples.map { ChartPoint(time: $0.timestamp, value: value($0)) },
            window: window,
            color: color,
            fillColor: fillColor,
            lineWidth: lineWidth,
            yRange: yRange,
            label: label,
            yFormatter: yFormatter,
            tooltipFormatter: tooltipFormatter
        )
    }

    private var domain: ChartTimeDomain { makeDomain([points], window: window, scale: scale, yFormatter: yFormatter) }
    private var scale: ChartYScale { chartYScale(for: [points], yRange: yRange) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinePlotCanvas(
                    points: points,
                    domain: domain,
                    scale: scale,
                    window: window,
                    color: color,
                    fillColor: fillColor,
                    lineWidth: lineWidth,
                    yFormatter: yFormatter
                )

                if let hx = hoverState.hoverX {
                    LineCrosshairCanvas(
                        points: points,
                        domain: domain,
                        scale: scale,
                        color: color,
                        hoverX: hx
                    )
                    .allowsHitTesting(false)

                    lineTooltip(geo: geo, hoverX: hx)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc): updateHover(hoverState, x: loc.x)
                case .ended: updateHover(hoverState, x: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func lineTooltip(geo: GeometryProxy, hoverX: CGFloat) -> some View {
        let plotW = geo.size.width - domain.leftPad
        let hoverTime = domain.time(atX: hoverX, plotW: plotW)
        if let idx = nearestIndex(in: points, to: hoverTime), let val = points[idx].value {
            let xPos = domain.x(for: points[idx].time, plotW: plotW)
            ChartTooltip(
                header: clockSecondFormatter.string(from: points[idx].time),
                values: [(color, label, tooltipFormatter(val), false)]
            )
            .fixedSize()
            .allowsHitTesting(false)
            .position(x: min(max(xPos, domain.leftPad + 40), max(geo.size.width - 40, domain.leftPad + 40)), y: 20)
        }
    }
}

// MARK: - Multi-Series Line Chart

/// Multi-series line chart using Canvas. All series share one wall-clock
/// x-domain, so differing sample counts stay aligned in time.
struct CanvasMultiLineChart: View {
    struct Series: Equatable {
        let points: [ChartPoint]
        let color: Color
        let label: String
        let dashed: Bool
        /// Optional area fill beneath the line.
        let fillColor: Color?

        init(points: [ChartPoint], color: Color, label: String = "", dashed: Bool = false, fillColor: Color? = nil) {
            self.points = points
            self.color = color
            self.label = label
            self.dashed = dashed
            self.fillColor = fillColor
        }

        /// Convenience: build from any timestamped snapshot array.
        init<T: TimestampedSample>(
            _ samples: [T],
            value: (T) -> Double?,
            color: Color,
            label: String = "",
            dashed: Bool = false,
            fillColor: Color? = nil
        ) {
            self.init(
                points: samples.map { ChartPoint(time: $0.timestamp, value: value($0)) },
                color: color,
                label: label,
                dashed: dashed,
                fillColor: fillColor
            )
        }
    }

    let series: [Series]
    let window: TimeInterval
    let yRange: ClosedRange<Double>?
    /// Round the axis in 1024-based steps, for byte rates.
    let binaryScale: Bool
    let yFormatter: (Double) -> String
    let tooltipFormatter: (Double) -> String

    @State private var hoverState = ChartHoverState()

    init(
        series: [Series],
        window: TimeInterval,
        yRange: ClosedRange<Double>? = nil,
        binaryScale: Bool = false,
        yFormatter: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        tooltipFormatter: @escaping (Double) -> String = { String(format: "%.1f", $0) }
    ) {
        self.series = series
        self.window = window
        self.yRange = yRange
        self.binaryScale = binaryScale
        self.yFormatter = yFormatter
        self.tooltipFormatter = tooltipFormatter
    }

    private var pointSets: [[ChartPoint]] { series.map(\.points) }

    private var domain: ChartTimeDomain { makeDomain(pointSets, window: window, scale: scale, yFormatter: yFormatter) }
    private var scale: ChartYScale { chartYScale(for: pointSets, yRange: yRange, binary: binaryScale) }

    /// Series used to snap the shared crosshair: the one with the most samples.
    private var referenceSeries: Series? {
        series.max { presentCount($0.points) < presentCount($1.points) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                MultiLinePlotCanvas(
                    series: series,
                    domain: domain,
                    scale: scale,
                    window: window,
                    yFormatter: yFormatter
                )

                if let hx = hoverState.hoverX {
                    MultiLineCrosshairCanvas(
                        series: series,
                        domain: domain,
                        scale: scale,
                        hoverX: hx
                    )
                    .allowsHitTesting(false)

                    multiTooltip(geo: geo, hoverX: hx)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc): updateHover(hoverState, x: loc.x)
                case .ended: updateHover(hoverState, x: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func multiTooltip(geo: GeometryProxy, hoverX: CGFloat) -> some View {
        let plotW = geo.size.width - domain.leftPad
        if let reference = referenceSeries,
           let refIdx = nearestIndex(in: reference.points, to: domain.time(atX: hoverX, plotW: plotW)) {
            let snapTime = reference.points[refIdx].time
            let xPos = domain.x(for: snapTime, plotW: plotW)
            let items: [(Color, String, String, Bool)] = series.compactMap { s in
                guard let idx = nearestIndex(in: s.points, to: snapTime),
                      let val = s.points[idx].value else { return nil }
                let lbl = s.label.isEmpty ? "Series" : s.label
                return (s.color, lbl, tooltipFormatter(val), s.dashed)
            }
            if !items.isEmpty {
                ChartTooltip(header: clockSecondFormatter.string(from: snapTime), values: items)
                    .fixedSize()
                    .allowsHitTesting(false)
                    .position(x: min(max(xPos, domain.leftPad + 50), max(geo.size.width - 50, domain.leftPad + 50)), y: 24)
            }
        }
    }
}

// MARK: - Gauge

/// Gauge view using Canvas
struct CanvasGauge: View {
    let percent: Double
    let color: Color
    let lineWidth: CGFloat

    init(percent: Double, color: Color, lineWidth: CGFloat = 6) {
        self.percent = percent
        self.color = color
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - lineWidth / 2

            // Background circle
            var bgPath = Path()
            bgPath.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            context.stroke(bgPath, with: .color(.secondary.opacity(0.15)), lineWidth: lineWidth)

            // Value arc
            let endAngle = 360 * min(percent / 100, 1)
            var valuePath = Path()
            valuePath.addArc(center: center, radius: radius,
                           startAngle: .degrees(-90), endAngle: .degrees(-90 + endAngle), clockwise: false)
            context.stroke(valuePath, with: .color(color),
                         style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

// MARK: - Shared History Card

/// Legend derived from the chart's own series, so it cannot drift from what is drawn.
struct ChartLegend: View {
    let series: [CanvasMultiLineChart.Series]

    var body: some View {
        let anyDashed = series.contains { $0.dashed }
        HStack(spacing: 16) {
            ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    if anyDashed {
                        ChartLineSwatch(color: item.color, dashed: item.dashed)
                    } else {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                    }
                    Text(item.label).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption2)
    }
}

/// Shown until enough samples exist to draw a line.
struct ChartEmptyState: View {
    var height: CGFloat = historyChartHeight

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

/// The title + range picker + chart + legend card that CPU, GPU, Memory, Disk,
/// Network and the Dashboard all previously spelled out for themselves.
struct HistoryChartCard<Accessory: View, Subheader: View>: View {
    let title: String
    var icon: String? = nil
    @Binding var range: HistoryRange
    let series: [CanvasMultiLineChart.Series]
    var yRange: ClosedRange<Double>? = nil
    var binaryScale = false
    var yFormatter: (Double) -> String = { String(format: "%.0f", $0) }
    var tooltipFormatter: (Double) -> String = { String(format: "%.1f", $0) }
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var subheader: () -> Subheader

    private var hasData: Bool {
        series.contains { $0.points.filter { $0.value != nil }.count >= 2 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let icon { Image(systemName: icon).foregroundStyle(.blue) }
                Text(title).font(.headline)
                Spacer()
                accessory()
            }

            subheader()

            HStack(spacing: 6) {
                Text("Range").font(.caption).foregroundStyle(.secondary)
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("History range")
            }

            if hasData {
                CanvasMultiLineChart(
                    series: series,
                    window: range.window,
                    yRange: yRange,
                    binaryScale: binaryScale,
                    yFormatter: yFormatter,
                    tooltipFormatter: tooltipFormatter
                )
                .frame(height: historyChartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title) chart, last \(range.rawValue)")
                .accessibilityValue(accessibilitySummary)

                ChartLegend(series: series)
            } else {
                ChartEmptyState()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Latest value of each series, so VoiceOver conveys the same thing a sighted
    /// user reads off the right edge of the chart.
    private var accessibilitySummary: String {
        series.compactMap { item -> String? in
            guard let latest = item.points.last(where: { $0.value != nil })?.value else { return nil }
            return "\(item.label) \(tooltipFormatter(latest))"
        }
        .joined(separator: ", ")
    }
}

extension HistoryChartCard where Accessory == EmptyView, Subheader == EmptyView {
    init(
        title: String,
        icon: String? = nil,
        range: Binding<HistoryRange>,
        series: [CanvasMultiLineChart.Series],
        yRange: ClosedRange<Double>? = nil,
        binaryScale: Bool = false,
        yFormatter: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        tooltipFormatter: @escaping (Double) -> String = { String(format: "%.1f", $0) }
    ) {
        self.init(title: title, icon: icon, range: range, series: series, yRange: yRange,
                  binaryScale: binaryScale,
                  yFormatter: yFormatter, tooltipFormatter: tooltipFormatter,
                  accessory: { EmptyView() }, subheader: { EmptyView() })
    }
}
