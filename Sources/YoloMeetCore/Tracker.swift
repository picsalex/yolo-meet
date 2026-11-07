import CoreGraphics

/// Assigns stable `trackID`s across frames by greedy IoU matching within a class.
/// Tracks survive `maxMisses` frames without a match so brief occlusions keep their identity.
public nonisolated final class Tracker {
    private struct Track {
        let id: Int
        var box: CGRect
        let classIndex: Int
        var misses = 0
    }

    private var tracks: [Track] = []
    private var nextID = 1
    private let minIoU: CGFloat
    private let maxMisses: Int

    public init(minIoU: CGFloat = 0.3, maxMisses: Int = 15) {
        self.minIoU = minIoU
        self.maxMisses = maxMisses
    }

    public func update(_ detections: inout [Detection]) {
        var pairs: [(track: Int, detection: Int, iou: CGFloat)] = []
        for (t, track) in tracks.enumerated() {
            for (d, detection) in detections.enumerated() where detection.classIndex == track.classIndex {
                let score = track.box.iou(detection.box)
                if score >= minIoU { pairs.append((t, d, score)) }
            }
        }
        var matchedTracks = Set<Int>()
        var matchedDetections = Set<Int>()
        for pair in pairs.sorted(by: { $0.iou > $1.iou })
        where !matchedTracks.contains(pair.track) && !matchedDetections.contains(pair.detection) {
            matchedTracks.insert(pair.track)
            matchedDetections.insert(pair.detection)
            tracks[pair.track].box = detections[pair.detection].box
            tracks[pair.track].misses = 0
            detections[pair.detection].trackID = tracks[pair.track].id
        }
        for t in tracks.indices where !matchedTracks.contains(t) { tracks[t].misses += 1 }
        tracks.removeAll { $0.misses > maxMisses }
        for d in detections.indices where !matchedDetections.contains(d) {
            tracks.append(Track(id: nextID, box: detections[d].box, classIndex: detections[d].classIndex))
            detections[d].trackID = nextID
            nextID += 1
        }
    }
}
