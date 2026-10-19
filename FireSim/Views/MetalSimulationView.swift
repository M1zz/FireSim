import SwiftUI
import MetalKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Hosts an MTKView that drives the simulation loop and blits the rendered field to screen.
struct MetalSimulationView: PlatformViewRepresentable {
    @ObservedObject var controller: SimulationController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    private func makeView(_ context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { makeView(context) }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    #else
    func makeUIView(context: Context) -> MTKView { makeView(context) }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    #endif

    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: SimulationController
        init(controller: SimulationController) { self.controller = controller }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                controller.tick()
                guard let drawable = view.currentDrawable,
                      let pass = view.currentRenderPassDescriptor,
                      let cb = controller.commandQueue.makeCommandBuffer(),
                      let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
                enc.setRenderPipelineState(controller.blitPipeline)
                enc.setFragmentTexture(controller.simulator.output, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
                cb.present(drawable)
                cb.commit()
            }
        }
    }
}
