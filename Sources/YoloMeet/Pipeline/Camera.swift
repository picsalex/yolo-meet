@preconcurrency import AVFoundation
import Observation

/// Camera selection and capture. Frames are delivered on a private queue to `onFrame`.
@Observable
final class Camera {
    private(set) var devices: [AVCaptureDevice] = []
    private(set) var authorized = false
    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            UserDefaults.standard.set(selectedID, forKey: "camera")
            configure()
        }
    }

    @ObservationIgnored private nonisolated(unsafe) let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCaptureVideoDataOutput()
    @ObservationIgnored private let receiver: FrameReceiver
    @ObservationIgnored private let queue = DispatchQueue(label: "camera", qos: .userInteractive)

    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        receiver = FrameReceiver(onFrame: onFrame)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(receiver, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    func start() async {
        authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { return }
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        ).devices
        let saved = UserDefaults.standard.string(forKey: "camera")
        selectedID = devices.first { $0.uniqueID == saved }?.uniqueID ?? devices.first?.uniqueID
    }

    private func configure() {
        guard let device = devices.first(where: { $0.uniqueID == selectedID }),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        if session.canAddInput(input) { session.addInput(input) }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        session.commitConfiguration()
        nonisolated(unsafe) let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }
}

private nonisolated final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    let onFrame: @Sendable (CVPixelBuffer) -> Void

    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) { self.onFrame = onFrame }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let buffer = sampleBuffer.imageBuffer { onFrame(buffer) }
    }
}
