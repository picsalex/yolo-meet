@preconcurrency import AVFoundation
import CoreImage
import Observation

/// Plays a media file into the pipeline like a camera: videos (muted, looping) frame by frame, images as a steady
/// stream so models and tracking behave as they do on live video. Both come at most at the camera's size.
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

    /// `onFrame` receives each frame, and whether it differs from the previous one.
    init(onFrame: @escaping @Sendable (CIImage, Bool) -> Void) {
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
            player.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { _ = self?.player.seek(to: .zero) } }  // loop
            isVideo = true
            Task {
                duration = (try? await item.asset.load(.duration).seconds) ?? 0
                // Frames scaled on the GPU to cover the camera's size, so a 4K video doesn't pass 4K frames around.
                var size: CVImageSize?
                if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                    let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
                {
                    let upright = natural.applying(transform)
                    let (w, h) = (abs(upright.width), abs(upright.height))
                    let scale = min(max(Pipeline.workingSize.width / w, Pipeline.workingSize.height / h), 1)
                    // Sides as stored (the transform applies later), even for the 4:2:0 decoder.
                    size = CVImageSize(width: Int(natural.width * scale / 2) * 2, height: Int(natural.height * scale / 2) * 2)
                }
                guard player.currentItem === item else { return }  // another file meanwhile
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes(
                    pixelFormatTypes: [CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA)], size: size,
                    compatibility: [.ioSurfaceCoreAnimation]))
                item.add(output)
                pump.set(output: output, image: nil)
            }
        } else {
            pump.set(output: nil, image: FileLibrary.image(at: url, covering: Pipeline.workingSize))
        }
        isPlaying = isActive && isVideo
    }

    func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Pulls video frames (or repeats the image) on its own queue and hands them to the pipeline. A paused or stalled
/// video keeps sending its current frame, like an image, so models enabled meanwhile still get frames to run on.
private nonisolated final class FramePump: @unchecked Sendable {
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    /// The image, or the video's latest frame.
    private var image: CIImage?
    /// The last frame sent (timer queue only).
    private var sent: CIImage?
    /// When the video last produced a new frame.
    private var fresh: CFTimeInterval = 0
    private var ticks = 0
    private let onFrame: @Sendable (CIImage, Bool) -> Void
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MediaPlayer", qos: .userInteractive))

    init(onFrame: @escaping @Sendable (CIImage, Bool) -> Void) {
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
        lock.withLock { (self.output, self.image, fresh) = (output, image, 0) }
    }

    private func tick() {
        ticks += 1
        let now = CACurrentMediaTime()
        let (output, image, fresh) = lock.withLock { (output, image, fresh) }
        if let output {
            let time = output.itemTime(forHostTime: now)
            if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.pixelBufferAndDisplayTime(forItemTime: time).0 {
                let frame = buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
                lock.withLock { (self.image, self.fresh) = (frame, now) }
                sent = frame
                return onFrame(frame, true)
            }
            guard now - fresh > 0.1 else { return }  // between two frames of a playing video
        }
        // A still (image, or paused video) at 30 fps, like a camera.
        if let image, ticks % 2 == 0 {
            defer { sent = image }
            onFrame(image, image !== sent)
        }
    }
}
