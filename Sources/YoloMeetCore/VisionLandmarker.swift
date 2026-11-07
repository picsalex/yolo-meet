import CoreImage
import Foundation
import Vision

/// Apple Vision's built-in hand, body and face landmarks, as detections with keypoints like the other models: hands in
/// MediaPipe's 21-point order, bodies in COCO's 17-point order, faces as Vision's landmark regions.
/// Faces are tracked: each frame's landmarks place the next frame's faces, so Vision skips face detection except every
/// `redetectEvery` frames or once a face is lost. Given a face's box, Vision returns landmarks whether or not a face is
/// still there; a tracked face under `trackedConfidence` (or a failed or partial tracking pass) means the face is gone
/// or slipping, so that frame runs face detection instead.
public nonisolated final class VisionLandmarker: @unchecked Sendable {
    public let id: String
    public let task: YOLOTask
    public let info: ModelInfo
    let redetectEvery = 10
    /// Landmark confidence a tracked face must keep: about 0.8–0.9 on faces, 0.65 on a box left on an empty wall.
    let trackedConfidence: Float = 0.7
    private let handler = VNSequenceRequestHandler()
    /// Faces for the next frame, each with how its detected box fit its landmarks.
    private var faces: [(face: VNFaceObservation, fit: Fit)] = []
    private var facesExtent = CGRect.null
    private var sinceDetection = 0

    /// Vision's hand joints in MediaPipe's order: wrist, then thumb, index, middle, ring and little finger, base to tip.
    private static let hand: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip, .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip, .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    /// Vision's body joints in COCO's order.
    private static let body: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]

    /// `id` is `vision-hand`, `vision-pose` or `vision-face`.
    public init(id: String) throws {
        guard let task = id.split(separator: "-").last.flatMap({ YOLOTask(rawValue: String($0)) }),
            [.hand, .pose, .face].contains(task)
        else { throw ModelError.invalid("unknown Apple Vision model \(id)") }
        self.id = id
        self.task = task
        info = ModelInfo(
            family: "Apple Vision", architecture: nil, parameters: nil, gflops: nil, isDynamic: false,
            precision: "built-in", bytes: 0)
    }

    public func predict(_ frame: CIImage) async throws -> ModelOutput {
        let start = CFAbsoluteTimeGetCurrent()
        let size = frame.extent.size
        var output = ModelOutput(
            modelID: id, task: task, names: task == .hand ? ["Left", "Right"] : [task == .face ? "face" : "person"],
            info: info, frameSize: size)
        output.inputSize = size
        // Vision's points are normalized with a bottom-left origin.
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
        func keypoint(_ p: VNRecognizedPoint?) -> Keypoint {
            p.map { Keypoint(point: point($0.location), confidence: $0.confidence) } ?? Keypoint(point: .zero, confidence: 0)
        }
        switch task {
        case .hand:
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            try handler.perform([request], on: frame)
            output.skeleton = MediaPipeConnections.hand
            output.detections = (request.results ?? []).map { hand in
                let joints = (try? hand.recognizedPoints(.all)) ?? [:]
                var detection = Detection(box: .zero, confidence: hand.confidence, classIndex: hand.chirality == .right ? 1 : 0)
                detection.keypoints = Self.hand.map { keypoint(joints[$0]) }
                return detection.boxed(minConfidence: 0.1)
            }
        case .pose:
            let request = VNDetectHumanBodyPoseRequest()
            try handler.perform([request], on: frame)
            output.detections = (request.results ?? []).map { body in
                let joints = (try? body.recognizedPoints(.all)) ?? [:]
                var detection = Detection(box: .zero, confidence: body.confidence, classIndex: 0)
                detection.keypoints = Self.body.map { keypoint(joints[$0]) }
                return detection.boxed(minConfidence: 0.1)
            }
        default:
            var request = VNDetectFaceLandmarksRequest()
            if frame.extent != facesExtent { (faces, facesExtent) = ([], frame.extent) }  // another input
            var tracked = !faces.isEmpty && sinceDetection < redetectEvery
            if tracked {
                request.inputFaceObservations = faces.map(\.face)
                let results = (try? handler.perform([request], on: frame)) != nil ? request.results ?? [] : []
                tracked = results.count == faces.count
                    && results.allSatisfy { ($0.landmarks?.confidence ?? 0) >= trackedConfidence }
            }
            if tracked {
                sinceDetection += 1
            } else {
                sinceDetection = 0
                request = VNDetectFaceLandmarksRequest()
                try handler.perform([request], on: frame)
            }
            let results = request.results ?? []
            // Tracked results come one per input face, in order.
            faces = results.enumerated().compactMap { i, face in
                guard let region = face.landmarks?.allPoints else { return nil }
                let box = face.boundingBox
                let bounds = region.normalizedPoints.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }.bounds
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                let fit = tracked && faces.indices.contains(i) ? faces[i].fit : Fit(box, around: bounds)
                return (VNFaceObservation(
                    requestRevision: face.requestRevision, boundingBox: fit.box(around: bounds), roll: face.roll,
                    yaw: face.yaw, pitch: face.pitch), fit)
            }
            var skeleton: [(Int, Int)] = []
            output.detections = results.compactMap { face in
                guard let landmarks = face.landmarks else { return nil }
                var detection = Detection(box: .zero, confidence: face.confidence, classIndex: 0)
                // Each region as a polyline; eyes and lips close into loops.
                let regions: [(VNFaceLandmarkRegion2D?, Bool)] = [
                    (landmarks.faceContour, false), (landmarks.leftEyebrow, false), (landmarks.rightEyebrow, false),
                    (landmarks.noseCrest, false), (landmarks.nose, true), (landmarks.leftEye, true),
                    (landmarks.rightEye, true), (landmarks.outerLips, true), (landmarks.innerLips, true),
                ]
                skeleton = []
                for case let (region?, closed) in regions {
                    let first = detection.keypoints.count
                    detection.keypoints += region.pointsInImage(imageSize: size).map {
                        Keypoint(point: CGPoint(x: $0.x, y: size.height - $0.y), confidence: 1)
                    }
                    let last = detection.keypoints.count - 1
                    guard last > first else { continue }
                    skeleton += (first..<last).map { ($0, $0 + 1) } + (closed ? [(last, first)] : [])
                }
                return detection.boxed(minConfidence: 0.1)
            }
            output.skeleton = skeleton
        }
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }

    /// A face box relative to the bounds of its landmarks: center offset and size, in units of the bounds.
    struct Fit {
        let dx, dy, width, height: CGFloat

        init(_ box: CGRect, around bounds: CGRect) {
            (dx, dy) = ((box.midX - bounds.midX) / bounds.width, (box.midY - bounds.midY) / bounds.height)
            (width, height) = (box.width / bounds.width, box.height / bounds.height)
        }

        func box(around bounds: CGRect) -> CGRect {
            let (w, h) = (width * bounds.width, height * bounds.height)
            return CGRect(x: bounds.midX + dx * bounds.width - w / 2, y: bounds.midY + dy * bounds.height - h / 2, width: w, height: h)
        }
    }
}
