import SwiftUI
import simd

/// The simulation viewport plus the editing overlay (fires, sensors, drag preview).
struct SimulationCanvas: View {
    @ObservedObject var controller: SimulationController
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if controller.isOfflinePlayback, let image = controller.currentOfflineImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    MetalSimulationView(controller: controller)
                }
                Canvas { ctx, _ in
                    drawOverlay(ctx, size: size)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        handleRelease(from: value.startLocation, to: value.location, size: size)
                        dragStart = nil
                        dragCurrent = nil
                    }
            )
            .clipped()
        }
        .aspectRatio(CGFloat(controller.plan.size.x / controller.plan.size.y), contentMode: .fit)
        .background(Color.black.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: Coordinate mapping

    private func world(_ p: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        SIMD2(Float(p.x / size.width) * controller.plan.size.x,
              Float(p.y / size.height) * controller.plan.size.y)
    }

    private func screen(_ w: SIMD2<Float>, _ size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(w.x / controller.plan.size.x) * size.width,
                y: CGFloat(w.y / controller.plan.size.y) * size.height)
    }

    private func metersToPoints(_ m: Float, _ size: CGSize) -> CGFloat {
        CGFloat(m / controller.plan.size.x) * size.width
    }

    // MARK: Interaction

    private func handleRelease(from a: CGPoint, to b: CGPoint, size: CGSize) {
        guard !controller.isOfflinePlayback else { return }
        let wa = world(a, size), wb = world(b, size)
        switch controller.editMode {
        case .wall: controller.addLine(kind: .wall, from: wa, to: wb)
        case .door: controller.addLine(kind: .door, from: wa, to: wb)
        case .window: controller.addLine(kind: .window, from: wa, to: wb)
        case .fire: controller.placeFire(at: wb)
        case .sensor: controller.placeSensor(at: wb)
        case .toggle: controller.toggleNearest(at: wb)
        case .erase: controller.eraseNearest(at: wb)
        }
    }

    // MARK: Overlay

    private func drawOverlay(_ ctx: GraphicsContext, size: CGSize) {
        let plan = controller.plan

        for fire in plan.fires {
            let c = screen(fire.position, size)
            let r = metersToPoints(fire.radius, size)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            let hrr = fire.hrr(at: controller.simTime)
            let label = Text(String(format: "%.0f kW", hrr)).font(.caption2.bold()).foregroundColor(.orange)
            ctx.draw(label, at: CGPoint(x: c.x, y: c.y - r - 8))
        }

        for sensor in plan.sensors {
            let c = screen(sensor.position, size)
            let reading = controller.latestReadings[sensor.id]
            let untenable = reading.map {
                $0.temperatureC > Tenability.maxTemperatureC ||
                $0.visibilityM < Tenability.minVisibilityM ||
                $0.coPPM > Tenability.maxCOppm
            } ?? false
            let color: Color = untenable ? .red : .green
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(color))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.white), lineWidth: 1.5)
            var text = sensor.name
            if let r = reading {
                text += String(format: "  %.0f°C  %.1fm  %.0fppm", r.temperatureC, r.visibilityM, r.coPPM)
            }
            ctx.draw(Text(text).font(.caption2).foregroundColor(.primary), at: CGPoint(x: c.x + 8, y: c.y - 8), anchor: .leading)
        }

        if let a = dragStart, let b = dragCurrent, controller.editMode.isLine {
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let color: Color = controller.editMode == .wall ? .black : (controller.editMode == .door ? .brown : .blue)
            ctx.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }

        if controller.isOfflinePlayback, let run = controller.offlineRun {
            let badge = Text("고해상도 재생 · \(run.resolution)px").font(.caption.bold()).foregroundColor(.white)
            ctx.fill(Path(roundedRect: CGRect(x: 8, y: 8, width: 170, height: 22), cornerRadius: 6), with: .color(.black.opacity(0.6)))
            ctx.draw(badge, at: CGPoint(x: 16, y: 19), anchor: .leading)
        }
    }
}
