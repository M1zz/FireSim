import Foundation
import Metal
import simd
import CoreGraphics
import Combine

struct SensorSample: Identifiable {
    var id: Int
    var time: Float
    var temperatureC: Float
    var visibilityM: Float
    var coPPM: Float
}

enum DisplayMode: UInt32, CaseIterable, Identifiable {
    case smoke = 0, temperature = 1, co = 2, visibility = 3
    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .smoke: return "연기"
        case .temperature: return "온도"
        case .co: return "CO"
        case .visibility: return "가시거리"
        }
    }
}

enum EditMode: String, CaseIterable, Identifiable {
    case wall, door, window, fire, sensor, toggle, erase
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wall: return "벽"
        case .door: return "문"
        case .window: return "창"
        case .fire: return "발화점"
        case .sensor: return "센서"
        case .toggle: return "개폐"
        case .erase: return "지우기"
        }
    }
    var isLine: Bool { self == .wall || self == .door || self == .window }
}

/// Rule-of-thumb tenability limits used for the charts and sensor badges.
enum Tenability {
    static let maxTemperatureC: Float = 60
    static let minVisibilityM: Float = 5
    static let maxCOppm: Float = 1200
}

struct OfflineFrame {
    var time: Float
    var image: CGImage
    var readings: [SensorReading]
}

struct OfflineRun {
    var resolution: Int
    var frames: [OfflineFrame]
    var displayMode: DisplayMode
}

@MainActor
final class SimulationController: ObservableObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let blitPipeline: MTLRenderPipelineState

    @Published var plan: FloorPlan { didSet { planDirty = true } }
    @Published var isRunning = false
    @Published var speed: Float = 1
    @Published var displayMode: DisplayMode = .smoke
    @Published var editMode: EditMode = .wall
    @Published var simTime: Float = 0
    @Published var resolution: Int = 192 { didSet { rebuildSimulator() } }
    @Published var jacobiIterations: Int = 40 { didSet { simulator.jacobiIterations = jacobiIterations } }
    @Published var sensorHistory: [UUID: [SensorSample]] = [:]
    @Published var latestReadings: [UUID: SensorReading] = [:]
    @Published var errorMessage: String?

    // Defaults applied to newly placed fires
    @Published var newFireGrowth: FireGrowth = .medium
    @Published var newFireMaxHRR: Float = 1000
    @Published var newFireRadius: Float = 0.5

    // Offline (high-resolution) mode
    @Published var offlineDuration: Float = 60
    @Published var offlineResolution: Int = 512
    @Published var offlineProgress: Double?
    @Published var offlineRun: OfflineRun?
    @Published var offlineFrameIndex: Int = 0
    @Published var isOfflinePlayback = false
    @Published private(set) var isOfflinePlaying = false

    private(set) var simulator: FluidSimulator
    private var planDirty = true
    private var lastSampleTime: Float = -1
    private let sampleInterval: Float = 0.25
    private var offlineTask: Task<Void, Never>?
    private var playbackTimer: Timer?
    /// Last edited plan per view mode, so switching views keeps each one's walls, fires and sensors.
    private var savedPlans: [ViewMode: FloorPlan] = [:]

    init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device")
        }
        self.device = device
        self.commandQueue = queue
        let plan = FloorPlan.demoSection()
        self.plan = plan

        let library = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "blitFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitPipeline = try! device.makeRenderPipelineState(descriptor: desc)

        simulator = try! FluidSimulator(device: device, resolution: 192, domainSize: plan.size, planMode: plan.viewMode == .plan)
    }

    var currentOfflineImage: CGImage? {
        guard let run = offlineRun, !run.frames.isEmpty else { return nil }
        return run.frames[min(offlineFrameIndex, run.frames.count - 1)].image
    }

    // MARK: - Frame loop (called from the MTKView delegate at display rate)

    func tick() {
        if planDirty {
            simulator.updateObstacles(plan.rasterize(width: simulator.width, height: simulator.height))
            planDirty = false
        }
        if isRunning && !isOfflinePlayback {
            let dt: Float = 1.0 / 120.0
            let frameTime = (1.0 / 60.0) * speed
            let substeps = max(1, Int((frameTime / dt).rounded()))
            for _ in 0..<substeps {
                let sources = plan.gpuSources(at: simulator.simTime, cellSize: simulator.cellSize)
                simulator.step(dt: dt, sources: sources)
            }
            simTime = simulator.simTime
            if simulator.simTime - lastSampleTime >= sampleInterval {
                sampleSensors()
            }
        }
        simulator.render(displayMode: displayMode.rawValue)
    }

    private func sampleSensors() {
        lastSampleTime = simulator.simTime
        let sensors = plan.sensors
        guard !sensors.isEmpty else { return }
        let cells = sensors.map { simulator.cell(for: $0.position) }
        let readings = simulator.sample(cells: cells)
        record(readings: readings, sensors: sensors, time: simulator.simTime)
    }

    private func record(readings: [SensorReading], sensors: [Sensor], time: Float) {
        for (sensor, r) in zip(sensors, readings) {
            latestReadings[sensor.id] = r
            var history = sensorHistory[sensor.id] ?? []
            history.append(SensorSample(id: history.count, time: time, temperatureC: r.temperatureC,
                                        visibilityM: r.visibilityM, coPPM: r.coPPM))
            if history.count > 4000 { history.removeFirst(history.count - 4000) }
            sensorHistory[sensor.id] = history
        }
    }

    // MARK: - Controls

    func reset() {
        simulator.reset()
        simTime = 0
        lastSampleTime = -1
        sensorHistory = [:]
        latestReadings = [:]
        isOfflinePlayback = false
    }

    func loadPreset(_ preset: FloorPlan) {
        isRunning = false
        plan = preset
        rebuildSimulator()
    }

    func setViewMode(_ mode: ViewMode) {
        guard plan.viewMode != mode else { return }
        if isOfflinePlayback { exitOfflinePlayback() }
        cancelOffline()
        savedPlans[plan.viewMode] = plan
        loadPreset(savedPlans[mode] ?? (mode == .section ? FloorPlan.demoSection() : FloorPlan.demoPlan()))
    }

    private func rebuildSimulator() {
        do {
            simulator = try FluidSimulator(device: device, resolution: resolution, domainSize: plan.size, planMode: plan.viewMode == .plan)
            simulator.jacobiIterations = jacobiIterations
            planDirty = true
            reset()
        } catch {
            errorMessage = "시뮬레이터 초기화 실패: \(error)"
        }
    }

    // MARK: - Editing

    func addLine(kind: ElementKind, from a: SIMD2<Float>, to b: SIMD2<Float>) {
        guard simd_distance(a, b) >= 0.3 else { return }
        var e = PlanElement(kind: kind, start: clampToDomain(a), end: clampToDomain(b))
        if kind == .door { e.isOpen = true }
        plan.elements.append(e)
    }

    func placeFire(at p: SIMD2<Float>) {
        plan.fires.append(FireSource(position: clampToDomain(p), radius: newFireRadius, growth: newFireGrowth,
                                     maxHRR: newFireMaxHRR, ignitionTime: simulator.simTime))
    }

    func placeSensor(at p: SIMD2<Float>) {
        plan.sensors.append(Sensor(position: clampToDomain(p), name: "센서 \(plan.sensors.count + 1)"))
    }

    func toggleNearest(at p: SIMD2<Float>) {
        guard let idx = plan.elements.indices
            .filter({ plan.elements[$0].kind != .wall })
            .min(by: { plan.elements[$0].distance(to: p) < plan.elements[$1].distance(to: p) }),
              plan.elements[idx].distance(to: p) < 0.8 else { return }
        plan.elements[idx].isOpen.toggle()
    }

    func eraseNearest(at p: SIMD2<Float>) {
        if let i = plan.fires.indices.min(by: { simd_distance(plan.fires[$0].position, p) < simd_distance(plan.fires[$1].position, p) }),
           simd_distance(plan.fires[i].position, p) < 0.8 {
            plan.fires.remove(at: i); return
        }
        if let i = plan.sensors.indices.min(by: { simd_distance(plan.sensors[$0].position, p) < simd_distance(plan.sensors[$1].position, p) }),
           simd_distance(plan.sensors[i].position, p) < 0.8 {
            let id = plan.sensors[i].id
            plan.sensors.remove(at: i)
            sensorHistory[id] = nil
            latestReadings[id] = nil
            return
        }
        if let i = plan.elements.indices.min(by: { plan.elements[$0].distance(to: p) < plan.elements[$1].distance(to: p) }),
           plan.elements[i].distance(to: p) < 0.6 {
            plan.elements.remove(at: i)
        }
    }

    private func clampToDomain(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(min(plan.size.x, max(0, p.x)), min(plan.size.y, max(0, p.y)))
    }

    // MARK: - Offline high-resolution run

    func runOffline() {
        guard offlineProgress == nil else { return }
        isRunning = false
        offlineProgress = 0
        let plan = self.plan
        let device = self.device
        let resolution = offlineResolution
        let duration = offlineDuration
        let mode = displayMode
        let snapshotInterval: Float = 0.25

        offlineTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let sim = try FluidSimulator(device: device, resolution: resolution, domainSize: plan.size, planMode: plan.viewMode == .plan)
                sim.jacobiIterations = 80
                sim.updateObstacles(plan.rasterize(width: sim.width, height: sim.height))
                let cells = plan.sensors.map { sim.cell(for: $0.position) }
                let dt: Float = 1.0 / 240.0
                var frames: [OfflineFrame] = []
                var nextSnapshot: Float = 0
                var lastProgressReport: Float = -1
                while sim.simTime < duration {
                    if Task.isCancelled { return }
                    sim.step(dt: dt, sources: plan.gpuSources(at: sim.simTime, cellSize: sim.cellSize))
                    if sim.simTime >= nextSnapshot {
                        sim.render(displayMode: mode.rawValue)
                        if let img = sim.snapshotImage() {
                            frames.append(OfflineFrame(time: sim.simTime, image: img, readings: sim.sample(cells: cells)))
                        }
                        nextSnapshot += snapshotInterval
                    }
                    if sim.simTime - lastProgressReport >= 1 {
                        lastProgressReport = sim.simTime
                        let progress = Double(sim.simTime / duration)
                        await MainActor.run { self?.offlineProgress = progress }
                    }
                }
                let run = OfflineRun(resolution: resolution, frames: frames, displayMode: mode)
                await MainActor.run { self?.finishOffline(run, plan: plan) }
            } catch {
                await MainActor.run {
                    self?.offlineProgress = nil
                    self?.errorMessage = "오프라인 계산 실패: \(error)"
                }
            }
        }
    }

    func cancelOffline() {
        offlineTask?.cancel()
        offlineTask = nil
        offlineProgress = nil
    }

    private func finishOffline(_ run: OfflineRun, plan: FloorPlan) {
        offlineProgress = nil
        offlineRun = run
        offlineFrameIndex = 0
        isOfflinePlayback = true
        sensorHistory = [:]
        latestReadings = [:]
        for frame in run.frames {
            record(readings: frame.readings, sensors: plan.sensors, time: frame.time)
        }
        simTime = run.frames.first?.time ?? 0
    }

    func exitOfflinePlayback() {
        stopOfflinePlayback()
        isOfflinePlayback = false
        reset()
    }

    /// Steps through the recorded offline frames at their capture interval (0.25 s).
    func toggleOfflinePlayback() {
        if isOfflinePlaying { stopOfflinePlayback(); return }
        guard let run = offlineRun, !run.frames.isEmpty else { return }
        if offlineFrameIndex >= run.frames.count - 1 { offlineFrameIndex = 0 }
        isOfflinePlaying = true
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let run = self.offlineRun else { return }
                if self.offlineFrameIndex + 1 < run.frames.count {
                    self.offlineFrameIndex += 1
                } else {
                    self.stopOfflinePlayback()
                }
            }
        }
    }

    func stopOfflinePlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        isOfflinePlaying = false
    }

    // MARK: - Export

    func csv() -> String {
        var lines = ["time_s,sensor,temperature_C,visibility_m,co_ppm"]
        for sensor in plan.sensors {
            for s in sensorHistory[sensor.id] ?? [] {
                let name = sensor.name.replacingOccurrences(of: ",", with: " ")
                lines.append(String(format: "%.2f,%@,%.1f,%.2f,%.0f", s.time, name, s.temperatureC, s.visibilityM, s.coPPM))
            }
        }
        return lines.joined(separator: "\n")
    }
}
