import SwiftUI

struct CutScrubberView: View {
    @ObservedObject var model: CutEditorModel
    @Environment(\.isEnabled) private var isEnabled

    private static let height: CGFloat = 24
    private static let trackTop: CGFloat = 6
    private static let trackBottom: CGFloat = 20
    private static let bandColors: [Color] = [.accentColor, .orange]
    private static let snapDistance: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(drag(width: geo.size.width))
        }
        .frame(height: Self.height)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Scrubber")
        .accessibilityValue("Frame \(model.currentFrame) of \(model.lastFrame)")
        .accessibilityAdjustableAction { direction in
            model.step(by: direction == .increment ? 1 : -1)
        }
    }

    private func x(forFrame frame: Int, width: CGFloat) -> CGFloat {
        guard model.lastFrame > 0 else { return 0 }
        return width * CGFloat(frame) / CGFloat(model.lastFrame)
    }

    private func frame(forX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, model.lastFrame > 0 else { return 0 }
        return Int((x / width * CGFloat(model.lastFrame)).rounded())
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled else { return }
                model.seek(to: frame(forX: value.location.x, width: width))
            }
            .onEnded { value in
                guard isEnabled else { return }
                let moved = abs(value.translation.width) + abs(value.translation.height)
                guard moved < 3 else { return }
                let nearest = model.splitPoints.min {
                    abs(x(forFrame: $0, width: width) - value.location.x)
                        < abs(x(forFrame: $1, width: width) - value.location.x)
                }
                if let nearest,
                   abs(x(forFrame: nearest, width: width) - value.location.x) <= Self.snapDistance {
                    model.seek(to: nearest)
                }
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let trackRect = CGRect(
            x: 0, y: Self.trackTop,
            width: width, height: Self.trackBottom - Self.trackTop)
        let trackPath = Path(roundedRect: trackRect, cornerRadius: 3)
        context.fill(trackPath, with: .color(Color(nsColor: .quaternaryLabelColor)))

        guard model.frameCount > 0 else { return }
        let selectionStart = model.inPoint ?? 0
        let selectionEnd = model.outPoint ?? model.lastFrame

        var bands = context
        bands.clip(to: trackPath)
        let ranges = SplitRanges.ranges(
            splits: model.splitPoints, inPoint: model.inPoint, outPoint: model.outPoint,
            lastFrame: model.lastFrame)
        for (n, range) in ranges.enumerated() {
            let startX = x(forFrame: range.inPoint ?? 0, width: width)
            let endX = x(forFrame: (range.outPoint ?? model.lastFrame) + 1, width: width)
            let band = CGRect(
                x: startX, y: trackRect.minY,
                width: max(2, endX - startX), height: trackRect.height)
            bands.fill(Path(band), with: .color(Self.bandColors[n % Self.bandColors.count].opacity(0.85)))
        }

        for split in model.inertSplitPoints {
            let markX = x(forFrame: split, width: width)
            var line = Path()
            line.move(to: CGPoint(x: markX, y: trackRect.minY))
            line.addLine(to: CGPoint(x: markX, y: trackRect.maxY))
            context.stroke(line, with: .color(.secondary.opacity(0.5)), lineWidth: 1.5)
        }

        for split in model.liveSplitPoints {
            let markX = x(forFrame: split, width: width)
            var line = Path()
            line.move(to: CGPoint(x: markX, y: trackRect.minY))
            line.addLine(to: CGPoint(x: markX, y: trackRect.maxY))
            context.stroke(line, with: .color(.white.opacity(0.95)), lineWidth: 2)
            var diamond = Path()
            diamond.move(to: CGPoint(x: markX, y: 0))
            diamond.addLine(to: CGPoint(x: markX + 3.5, y: 3))
            diamond.addLine(to: CGPoint(x: markX, y: Self.trackTop))
            diamond.addLine(to: CGPoint(x: markX - 3.5, y: 3))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(.primary))
        }

        bracket(in: &context, at: x(forFrame: selectionStart, width: width),
                rect: trackRect, opensRight: true)
        bracket(in: &context, at: x(forFrame: selectionEnd + 1, width: width),
                rect: trackRect, opensRight: false)

        let headX = x(forFrame: model.currentFrame, width: width)
        var head = Path()
        head.move(to: CGPoint(x: headX, y: 0))
        head.addLine(to: CGPoint(x: headX, y: size.height))
        context.stroke(head, with: .color(.primary), lineWidth: 2)
    }

    private func bracket(in context: inout GraphicsContext, at x: CGFloat,
                         rect: CGRect, opensRight: Bool) {
        let serif: CGFloat = opensRight ? 4 : -4
        var path = Path()
        path.move(to: CGPoint(x: x + serif, y: rect.minY - 2))
        path.addLine(to: CGPoint(x: x, y: rect.minY - 2))
        path.addLine(to: CGPoint(x: x, y: rect.maxY + 2))
        path.addLine(to: CGPoint(x: x + serif, y: rect.maxY + 2))
        context.stroke(path, with: .color(.primary.opacity(0.9)), lineWidth: 2)
    }
}
