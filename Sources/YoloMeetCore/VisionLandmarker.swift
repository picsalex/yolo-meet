import CoreImage
import Foundation
import Vision

/// Apple Vision's built-in hand, body and face landmarks, as detections with keypoints like the other models: hands in
/// MediaPipe's 21-point order, bodies in COCO's 17-point order, faces as Vision's landmark regions.
public nonisolated final class VisionLandmarker: @unchecked Sendable {
    public let id: String
    public let task: YOLOTask
    public let info: ModelInfo
    private let handler = VNSequenceRequestHandler()

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
        else { throw YOLOModelError.invalid("unknown Apple Vision model \(id)") }
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
                return detection.boxed()
            }
        case .pose:
            let request = VNDetectHumanBodyPoseRequest()
            try handler.perform([request], on: frame)
            output.detections = (request.results ?? []).map { body in
                let joints = (try? body.recognizedPoints(.all)) ?? [:]
                var detection = Detection(box: .zero, confidence: body.confidence, classIndex: 0)
                detection.keypoints = Self.body.map { keypoint(joints[$0]) }
                return detection.boxed()
            }
        default:
            let request = VNDetectFaceLandmarksRequest()
            try handler.perform([request], on: frame)
            var skeleton: [(Int, Int)] = []
            output.detections = (request.results ?? []).compactMap { face in
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
                return detection.boxed()
            }
            output.skeleton = skeleton
        }
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }
}

private nonisolated extension Detection {
    /// Sets the box around the confident keypoints.
    func boxed() -> Detection {
        let points = keypoints.filter { $0.confidence > 0.1 }.map(\.point)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(),
            let maxY = points.map(\.y).max()
        else { return self }
        var detection = self
        detection.box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return detection
    }
}
