import CoreMotion
import MetalKit
import SwiftUI

/// Interactive 360° viewer: drag to look around, pinch to zoom, optionally steer with
/// the phone's motion. Renders with a tiny Metal shader straight from the equirectangular JPEG.
struct PanoramaViewer: UIViewRepresentable {
    let url: URL
    var useMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.backgroundColor = .black
        context.coordinator.attach(to: view)
        context.coordinator.load(url: url)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setMotion(useMotion)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.setMotion(false)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private weak var view: MTKView?

        private var yaw: Float = 0
        private var pitch: Float = 0
        private var fovY: Float = 75 * .pi / 180
        private var pinchStartFov: Float = 0

        private let motion = CMMotionManager()
        private var motionActive = false
        private var motionYawOffset: Float?

        struct Uniforms { var yaw: Float; var pitch: Float; var tanHalfFovY: Float; var aspect: Float }

        func attach(to view: MTKView) {
            self.view = view
            view.delegate = self
            guard let device = view.device else { return }
            self.device = device
            queue = device.makeCommandQueue()
            guard let library = device.makeDefaultLibrary() else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "pano_vertex")
            desc.fragmentFunction = library.makeFunction(name: "pano_fragment")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        private var url: URL?

        override init() {
            super.init()
            // Opened from a notification while the app was still in the background: the GPU is
            // not available then, so (re)load and redraw once the app is active.
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @objc private func becameActive() {
            if texture == nil, let url { load(url: url) }
            view?.setNeedsDisplay()
        }

        func load(url: URL) {
            self.url = url
            guard let device else { return }
            let loader = MTKTextureLoader(device: device)
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ]
            loader.newTexture(URL: url, options: options) { [weak self] tex, _ in
                DispatchQueue.main.async {
                    self?.texture = tex
                    self?.view?.setNeedsDisplay()
                }
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            // Radians per point so the content follows the finger.
            let k = 2 * tan(fovY / 2) / Float(max(view.bounds.height, 1))
            if motionActive {
                motionYawOffset = (motionYawOffset ?? 0) - Float(t.x) * k
            } else {
                yaw -= Float(t.x) * k
                pitch = max(-.pi / 2, min(.pi / 2, pitch + Float(t.y) * k))
            }
            view.setNeedsDisplay()
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { pinchStartFov = fovY }
            fovY = max(30 * .pi / 180, min(110 * .pi / 180, pinchStartFov / Float(g.scale)))
            view?.setNeedsDisplay()
        }

        func setMotion(_ on: Bool) {
            guard on != motionActive else { return }
            motionActive = on
            if on, motion.isDeviceMotionAvailable {
                motionYawOffset = nil
                motion.deviceMotionUpdateInterval = 1 / 60
                motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
                    guard let self, let m else { return }
                    let r = m.attitude.rotationMatrix
                    // Device -z (looking through the back camera) in the reference frame (z up).
                    let dx = Float(-r.m31), dy = Float(-r.m32), dz = Float(-r.m33)
                    let deviceYaw = atan2(dx, dy)
                    let devicePitch = asin(max(-1, min(1, dz)))
                    if self.motionYawOffset == nil { self.motionYawOffset = self.yaw - deviceYaw }
                    self.yaw = (self.motionYawOffset ?? 0) + deviceYaw
                    self.pitch = devicePitch
                    self.view?.setNeedsDisplay()
                }
            } else {
                motion.stopDeviceMotionUpdates()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let pipeline, let queue, let texture,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            let size = view.drawableSize
            var u = Uniforms(yaw: yaw, pitch: pitch, tanHalfFovY: tan(fovY / 2),
                             aspect: Float(size.width / max(size.height, 1)))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
