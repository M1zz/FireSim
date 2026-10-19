import Foundation
import Metal
import simd
import CoreGraphics

struct SensorReading {
    var temperatureK: Float
    var sootDensity: Float   // kg/m^3
    var coDensity: Float     // kg/m^3

    var temperatureC: Float { temperatureK - 273.15 }
    /// Jin's relation: S = C / K with K = Km · Cs, Km = 8700 m²/kg, C = 3 (reflective signs).
    var visibilityM: Float {
        let k = 8700 * sootDensity
        return k > 1e-4 ? min(30, 3 / k) : 30
    }
    var coPPM: Float { coDensity / 1.2 * 1.0357e6 }
}

/// GPU stable-fluids solver with buoyancy, combustion sources, obstacles and vents.
/// All methods may be called from any single thread; the class is not internally synchronized.
final class FluidSimulator: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let width: Int
    let height: Int
    let cellSize: Float
    var params: SimParams
    var jacobiIterations: Int = 40
    private(set) var simTime: Float = 0

    private var velocity: [MTLTexture]
    private var temperature: [MTLTexture]
    private var smoke: [MTLTexture]
    private var co: [MTLTexture]
    private var pressure: [MTLTexture]
    private let divergence: MTLTexture
    private let curl: MTLTexture
    private let obstacles: MTLTexture
    let output: MTLTexture

    private let readback: MTLBuffer
    private let planeBytes: Int
    private let sourceBuffer: MTLBuffer
    private let maxSources = 64

    private let pipelines: [String: MTLComputePipelineState]
    private static let kernelNames = [
        "clearFields", "applyForcesAndSources", "computeCurl", "applyVorticity",
        "advectVelocity", "advectScalar", "computeDivergence", "jacobi",
        "subtractGradient", "renderOutput",
    ]

    init(device: MTLDevice, resolution: Int, domainSize: SIMD2<Float>, planMode: Bool) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SimError.noQueue }
        self.queue = queue

        let w = resolution
        let h = max(16, Int((Float(resolution) * domainSize.y / domainSize.x).rounded()))
        width = w
        height = h
        cellSize = domainSize.x / Float(w)

        var p = SimParams()
        p.gridSize = SIMD2<UInt32>(UInt32(w), UInt32(h))
        p.dx = cellSize
        p.dt = 1.0 / 120.0
        p.ambientTemp = 293.15
        p.gravity = 9.81
        p.buoyancy = 1.0
        p.vorticity = 2.0
        p.coolingRate = 0.15
        p.smokeDissipation = 0.999
        p.velocityDissipation = 0.998
        p.rhoCp = 1.2
        p.cellDepth = 1.0
        p.expansion = 1.5
        p.sourceCount = 0
        p.planMode = planMode ? 1 : 0
        p.displayMode = 0
        params = p

        guard let library = device.makeDefaultLibrary() else { throw SimError.noLibrary }
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in Self.kernelNames {
            guard let fn = library.makeFunction(name: name) else { throw SimError.missingKernel(name) }
            pipelines[name] = try device.makeComputePipelineState(function: fn)
        }
        self.pipelines = pipelines

        func make(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        velocity = [make(.rg32Float), make(.rg32Float)]
        temperature = [make(.r32Float), make(.r32Float)]
        smoke = [make(.r32Float), make(.r32Float)]
        co = [make(.r32Float), make(.r32Float)]
        pressure = [make(.r32Float), make(.r32Float)]
        divergence = make(.r32Float)
        curl = make(.r32Float)
        output = make(.bgra8Unorm)

        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
        od.usage = [.shaderRead]
        #if os(macOS)
        od.storageMode = .managed
        #else
        od.storageMode = .shared
        #endif
        obstacles = device.makeTexture(descriptor: od)!

        planeBytes = w * h * 4
        readback = device.makeBuffer(length: planeBytes * 3, options: .storageModeShared)!
        sourceBuffer = device.makeBuffer(length: MemoryLayout<FireSourceGPU>.stride * maxSources, options: .storageModeShared)!

        reset()
    }

    enum SimError: Error { case noQueue, noLibrary, missingKernel(String) }

    // MARK: - Public API

    func reset() {
        simTime = 0
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        dispatch(enc, "clearFields", [velocity[0], temperature[0], smoke[0], co[0], pressure[0]])
        dispatch(enc, "clearFields", [velocity[1], temperature[1], smoke[1], co[1], pressure[1]])
        enc.endEncoding()
        cb.commit()
    }

    func updateObstacles(_ cells: [UInt8]) {
        precondition(cells.count == width * height)
        cells.withUnsafeBytes { ptr in
            obstacles.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                              withBytes: ptr.baseAddress!, bytesPerRow: width)
        }
    }

    func cell(for position: SIMD2<Float>) -> SIMD2<Int> {
        let x = min(width - 1, max(0, Int(position.x / cellSize)))
        let y = min(height - 1, max(0, Int(position.y / cellSize)))
        return SIMD2(x, y)
    }

    /// Advances the simulation by one substep of `dt` seconds.
    func step(dt: Float, sources: [FireSourceGPU]) {
        params.dt = dt
        let count = min(sources.count, maxSources)
        params.sourceCount = UInt32(count)
        if count > 0 {
            sources.withUnsafeBufferPointer { ptr in
                memcpy(sourceBuffer.contents(), ptr.baseAddress!, MemoryLayout<FireSourceGPU>.stride * count)
            }
        }

        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setBuffer(sourceBuffer, offset: 0, index: 1)

        dispatch(enc, "applyForcesAndSources",
                 [velocity[0], temperature[0], smoke[0], co[0], obstacles,
                  velocity[1], temperature[1], smoke[1], co[1]])
        velocity.swapAt(0, 1); temperature.swapAt(0, 1); smoke.swapAt(0, 1); co.swapAt(0, 1)

        if params.vorticity > 0 {
            dispatch(enc, "computeCurl", [velocity[0], obstacles, curl])
            dispatch(enc, "applyVorticity", [velocity[0], curl, obstacles, velocity[1]])
            velocity.swapAt(0, 1)
        }

        dispatch(enc, "advectVelocity", [velocity[0], obstacles, velocity[1]])
        velocity.swapAt(0, 1)

        var tempAdvect = ScalarAdvectParams(dissipation: 1.0, ambient: params.ambientTemp)
        enc.setBytes(&tempAdvect, length: MemoryLayout<ScalarAdvectParams>.stride, index: 2)
        dispatch(enc, "advectScalar", [temperature[0], velocity[0], obstacles, temperature[1]])
        temperature.swapAt(0, 1)

        var smokeAdvect = ScalarAdvectParams(dissipation: params.smokeDissipation, ambient: 0)
        enc.setBytes(&smokeAdvect, length: MemoryLayout<ScalarAdvectParams>.stride, index: 2)
        dispatch(enc, "advectScalar", [smoke[0], velocity[0], obstacles, smoke[1]])
        smoke.swapAt(0, 1)
        dispatch(enc, "advectScalar", [co[0], velocity[0], obstacles, co[1]])
        co.swapAt(0, 1)

        dispatch(enc, "computeDivergence", [velocity[0], obstacles, divergence])
        for _ in 0..<jacobiIterations {
            dispatch(enc, "jacobi", [pressure[0], divergence, obstacles, pressure[1]])
            pressure.swapAt(0, 1)
        }
        dispatch(enc, "subtractGradient", [velocity[0], pressure[0], obstacles, velocity[1]])
        velocity.swapAt(0, 1)

        enc.endEncoding()
        cb.commit()
        simTime += dt
    }

    /// Renders the current state into `output` with the given display mode (0 smoke, 1 temp, 2 CO, 3 visibility).
    func render(displayMode: UInt32) {
        params.displayMode = displayMode
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        dispatch(enc, "renderOutput", [temperature[0], smoke[0], co[0], velocity[0], obstacles, output])
        enc.endEncoding()
        cb.commit()
    }

    /// Reads back T, soot and CO at the given cells. Blocks until the GPU has finished.
    func sample(cells: [SIMD2<Int>]) -> [SensorReading] {
        guard !cells.isEmpty, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return [] }
        let size = MTLSize(width: width, height: height, depth: 1)
        for (i, tex) in [temperature[0], smoke[0], co[0]].enumerated() {
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: size, to: readback, destinationOffset: planeBytes * i,
                      destinationBytesPerRow: width * 4, destinationBytesPerImage: planeBytes)
        }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let base = readback.contents().assumingMemoryBound(to: Float.self)
        let plane = width * height
        return cells.map { c in
            let idx = c.y * width + c.x
            return SensorReading(temperatureK: base[idx], sootDensity: base[plane + idx], coDensity: base[2 * plane + idx])
        }
    }

    /// Copies the rendered `output` texture into a CGImage. Blocks until the GPU has finished.
    func snapshotImage() -> CGImage? {
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                  destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: planeBytes)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let data = Data(bytes: readback.contents(), count: planeBytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Private

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ name: String, _ textures: [MTLTexture]) {
        guard let pso = pipelines[name] else { return }
        enc.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        var p = params
        enc.setBytes(&p, length: MemoryLayout<SimParams>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
    }
}
