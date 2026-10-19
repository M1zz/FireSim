import Foundation
import simd

/// Cell classification uploaded to the GPU obstacle texture.
enum CellType: UInt8 {
    case fluid = 0
    case wall = 1
    case doorClosed = 2
    case doorOpen = 3
    case windowClosed = 4
    case windowOpen = 5
}

enum ElementKind: String, Codable, CaseIterable, Identifiable {
    case wall, door, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wall: return "벽"
        case .door: return "문"
        case .window: return "창문"
        }
    }
}

struct PlanElement: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ElementKind
    var start: SIMD2<Float>   // meters
    var end: SIMD2<Float>     // meters
    var thickness: Float = 0.2
    var isOpen: Bool = false

    var cellType: CellType {
        switch kind {
        case .wall: return .wall
        case .door: return isOpen ? .doorOpen : .doorClosed
        case .window: return isOpen ? .windowOpen : .windowClosed
        }
    }

    var length: Float { simd_distance(start, end) }

    func distance(to p: SIMD2<Float>) -> Float {
        let ab = end - start
        let len2 = simd_dot(ab, ab)
        let t: Float = len2 > 0 ? max(0, min(1, simd_dot(p - start, ab) / len2)) : 0
        return simd_distance(p, start + ab * t)
    }
}

/// NFPA 92 / SFPE t-squared fire growth classes.
enum FireGrowth: String, Codable, CaseIterable, Identifiable {
    case slow, medium, fast, ultrafast
    var id: String { rawValue }
    /// Growth coefficient alpha in kW/s^2
    var alpha: Float {
        switch self {
        case .slow: return 0.00293
        case .medium: return 0.01172
        case .fast: return 0.0469
        case .ultrafast: return 0.1876
        }
    }
    var label: String {
        switch self {
        case .slow: return "느림 (slow)"
        case .medium: return "보통 (medium)"
        case .fast: return "빠름 (fast)"
        case .ultrafast: return "초고속 (ultrafast)"
        }
    }
}

struct FireSource: Identifiable, Codable, Equatable {
    var id = UUID()
    var position: SIMD2<Float>      // meters
    var radius: Float = 0.5         // meters
    var growth: FireGrowth = .medium
    var maxHRR: Float = 1000        // kW
    var ignitionTime: Float = 0     // seconds
    var sootYield: Float = 0.10     // kg soot / kg fuel (flaming polyurethane ~0.1)
    var coYield: Float = 0.04       // kg CO / kg fuel
    var heatOfCombustion: Float = 20_000 // kJ/kg

    /// Heat release rate at simulation time t (kW).
    func hrr(at t: Float) -> Float {
        let elapsed = t - ignitionTime
        guard elapsed > 0 else { return 0 }
        return min(growth.alpha * elapsed * elapsed, maxHRR)
    }

    func massLossRate(at t: Float) -> Float { hrr(at: t) / heatOfCombustion }
}

struct Sensor: Identifiable, Codable, Equatable {
    var id = UUID()
    var position: SIMD2<Float>
    var name: String
}

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case plan, section
    var id: String { rawValue }
    var label: String { self == .section ? "단면 (측면)" : "평면 (위에서)" }
    var symbol: String { self == .section ? "rectangle.split.1x2" : "square.grid.2x2" }
}

struct FloorPlan: Codable, Equatable {
    var size: SIMD2<Float> = SIMD2(16, 6)
    var viewMode: ViewMode = .section
    var elements: [PlanElement] = []
    var fires: [FireSource] = []
    var sensors: [Sensor] = []

    /// Rasterizes elements into a width×height cell grid. Doors/windows are drawn after walls so
    /// they punch openings into them.
    func rasterize(width: Int, height: Int) -> [UInt8] {
        var cells = [UInt8](repeating: 0, count: width * height)
        let dx = size.x / Float(width)
        let dy = size.y / Float(height)
        let ordered = elements.filter { $0.kind == .wall } + elements.filter { $0.kind != .wall }
        for e in ordered {
            let half = max(e.thickness / 2, dx * 0.6)
            let minX = max(0, Int(floor((min(e.start.x, e.end.x) - half) / dx)))
            let maxX = min(width - 1, Int(ceil((max(e.start.x, e.end.x) + half) / dx)))
            let minY = max(0, Int(floor((min(e.start.y, e.end.y) - half) / dy)))
            let maxY = min(height - 1, Int(ceil((max(e.start.y, e.end.y) + half) / dy)))
            guard minX <= maxX, minY <= maxY else { continue }
            let value = e.cellType.rawValue
            for j in minY...maxY {
                for i in minX...maxX {
                    let p = SIMD2<Float>((Float(i) + 0.5) * dx, (Float(j) + 0.5) * dy)
                    if e.distance(to: p) <= half {
                        cells[j * width + i] = value
                    }
                }
            }
        }
        return cells
    }

    func gpuSources(at time: Float, cellSize: Float) -> [FireSourceGPU] {
        fires.compactMap { f in
            let q = f.hrr(at: time)
            guard q > 0 else { return nil }
            let m = q / f.heatOfCombustion
            return FireSourceGPU(position: f.position / cellSize,
                                 radius: f.radius / cellSize,
                                 heatRelease: q,
                                 sootRate: m * f.sootYield,
                                 coRate: m * f.coYield)
        }
    }

    // MARK: Presets

    /// A 16 m × 6 m room cross-section: floor, ceiling, a door on the right, a window near the ceiling on the left.
    static func demoSection() -> FloorPlan {
        var plan = FloorPlan(size: SIMD2(16, 6), viewMode: .section)
        plan.elements = [
            PlanElement(kind: .wall, start: [0.2, 5.6], end: [15.8, 5.6], thickness: 0.3),   // floor
            PlanElement(kind: .wall, start: [0.2, 0.4], end: [15.8, 0.4], thickness: 0.3),   // ceiling
            PlanElement(kind: .wall, start: [0.2, 0.4], end: [0.2, 5.6], thickness: 0.3),    // left wall
            PlanElement(kind: .wall, start: [15.8, 0.4], end: [15.8, 5.6], thickness: 0.3),  // right wall
            PlanElement(kind: .window, start: [0.2, 0.8], end: [0.2, 1.8], thickness: 0.3, isOpen: false),
            PlanElement(kind: .door, start: [15.8, 3.3], end: [15.8, 5.4], thickness: 0.3, isOpen: true),
            PlanElement(kind: .wall, start: [9.0, 0.4], end: [9.0, 1.6], thickness: 0.2),    // soffit / beam
        ]
        plan.fires = [FireSource(position: [4.0, 5.1], radius: 0.5, growth: .medium, maxHRR: 1000)]
        plan.sensors = [
            Sensor(position: [4.0, 1.0], name: "천장 위 화원"),
            Sensor(position: [12.0, 1.0], name: "천장 출구측"),
            Sensor(position: [12.0, 4.0], name: "호흡 높이 출구측"),
        ]
        return plan
    }

    /// A 16 m × 12 m top-down apartment: two rooms with a connecting door, a window, exit door.
    static func demoPlan() -> FloorPlan {
        var plan = FloorPlan(size: SIMD2(16, 12), viewMode: .plan)
        plan.elements = [
            PlanElement(kind: .wall, start: [0.2, 0.2], end: [15.8, 0.2], thickness: 0.3),
            PlanElement(kind: .wall, start: [0.2, 11.8], end: [15.8, 11.8], thickness: 0.3),
            PlanElement(kind: .wall, start: [0.2, 0.2], end: [0.2, 11.8], thickness: 0.3),
            PlanElement(kind: .wall, start: [15.8, 0.2], end: [15.8, 11.8], thickness: 0.3),
            PlanElement(kind: .wall, start: [8.0, 0.2], end: [8.0, 11.8], thickness: 0.25),    // partition
            PlanElement(kind: .door, start: [8.0, 5.0], end: [8.0, 6.2], thickness: 0.25, isOpen: true),
            PlanElement(kind: .window, start: [0.2, 3.0], end: [0.2, 5.0], thickness: 0.3),
            PlanElement(kind: .door, start: [15.8, 9.0], end: [15.8, 10.2], thickness: 0.3, isOpen: false),
        ]
        plan.fires = [FireSource(position: [3.0, 8.5], radius: 0.6, growth: .fast, maxHRR: 1500)]
        plan.sensors = [
            Sensor(position: [5.5, 5.0], name: "화재실"),
            Sensor(position: [12.0, 6.0], name: "옆방"),
            Sensor(position: [14.5, 9.6], name: "출구"),
        ]
        return plan
    }
}
