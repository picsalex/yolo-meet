@preconcurrency import AVFoundation
import CoreImage
import Observation

/// Plays a media file into the pipeline like a camera: videos (muted, looping) frame by frame, images as a steady
/// stream so models and tracking behave as they do on live video.
@Observable
final class MediaPlayer {
    private(set) var isVideo = false
    private(set) var duration: Double = 0
    /// Playback position in seconds, updated a few times a second.
    private(set) var time: Double = 0
    var isPlaying = false { didSet { isPlaying && isActive ? player.play() : player.pause() } }
    /// Frames flow only while the stage shows media.
    var isActive = false {
        didSet {
            pump.isActive = isActive
            isPlaying = isActive && isVideo
        }
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let pump: FramePump
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    init(onFrame: @escaping @Sendable (CIImage) -> Void) {
        pump = FramePump(onFrame: onFrame)
        player.isMuted = true
        player.actionAtItemEnd = .none
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in MainActor.assumeIsolated { self?.time = time.seconds } }
    }

    /// Shows `url` (an image or a video), or nothing.
    func load(_ url: URL?) {
        player.replaceCurrentItem(with: nil)
        endObserver.map(NotificationCenter.default.removeObserver)
        pump.set(output: nil, image: nil)
        (isVideo, duration, time) = (false, 0, 0)
        guard let url else { return }
        if FileLibrary.isVideo(url) {
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes(
                pixelFormatTypes: [CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA)], compatibility: [.ioSurfaceCoreAnimation]))
            item.add(output)
            player.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { _ = self?.player.seek(to: .zero) } }  // loop
            pump.set(output: output, image: nil)
            isVideo = true
            Task { duration = (try? await item.asset.load(.duration).seconds) ?? 0 }
        } else {
            pump.set(output: nil, image: CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        }
        isPlaying = isActive && isVideo
    }

    func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Pulls video frames (or repeats the image) on its own queue and hands them to the pipeline.
private nonisolated final class FramePump: @unchecked Sendable {
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private var image: CIImage?
    private var ticks = 0
    private let onFrame: @Sendable (CIImage) -> Void
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MediaPlayer", qos: .userInteractive))

    init(onFrame: @escaping @Sendable (CIImage) -> Void) {
        self.onFrame = onFrame
        timer.schedule(deadline: .now(), repeating: 1.0 / 60)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.activate()
        timer.suspend()
    }

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? timer.resume() : timer.suspend()
        }
    }

    deinit {
        if !isActive { timer.resume() }  // a suspended source must not be released
        timer.cancel()
    }

    func set(output: AVPlayerItemVideoOutput?, image: CIImage?) {
        lock.withLock { (self.output, self.image) = (output, image) }
    }

    private func tick() {
        let (output, image) = lock.withLock { (output, image) }
        if let output {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time), let buffer = output.pixelBufferAndDisplayTime(forItemTime: time).0
            else { return }
            onFrame(buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) })
        } else if let image {
            ticks += 1
            if ticks % 2 == 0 { onFrame(image) }  // 30 fps, like a camera
        }
    }
}
