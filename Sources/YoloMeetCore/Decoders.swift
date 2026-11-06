import Accelerate
import CoreGraphics

/// Decoders for the raw (non end-to-end) Ultralytics Core AI heads:
/// - detect `[1, 4+nc, A]`, segment `[1, 4+nc+32, A]` + protos `[1, 32, 160, 160]`, pose `[1, 4+1+K*3, A]`,
///   obb `[1, 4+nc+1, A]` — boxes are center xywh in model-input pixels, scores are already sigmoid-activated.
/// - classify `[1, nc]` probabilities, semantic `[1, nc, H, W]` logits, depth `[1, 1, H, W]`.
nonisolated extension YOLOModel {
    static let maxDetections = 100

    func decode(_ tensors: [Tensor], geometry: Geometry, into output: inout ModelOutput) {
        let head = tensors[0]
        switch task {
        case .detect:
            output.detections = boxes(head, classes: head.shape[1] - 4, geometry: geometry).map(\.detection)
        case .segment:
            let protos = tensors[1]
            let kept = boxes(head, classes: head.shape[1] - 4 - protos.shape[1], geometry: geometry)
            output.detections = kept.map(\.detection)
            output.overlay = instanceMasks(kept, head: head, protos: protos, geometry: geometry)
        case .pose:
            output.detections = boxes(head, classes: 1, geometry: geometry).map { candidate in
                var detection = candidate.detection
                let anchors = head.shape[2]
                detection.keypoints = stride(from: 5, to: head.shape[1] - 2, by: 3).map { row in
                    let value = { head.values[($0) * anchors + candidate.anchor] }
                    return Keypoint(point: geometry.point(value(row), value(row + 1)), confidence: value(row + 2))
                }
                return detection
            }
        case .obb:
            output.detections = boxes(head, classes: head.shape[1] - 5, geometry: geometry, rotated: true).map(\.detection)
        case .classify:
            output.topClasses = head.values.indices.sorted { head.values[$0] > head.values[$1] }.prefix(5)
                .map { ($0, head.values[$0]) }
        case .semantic:
            output.overlay = classMap(head, geometry: geometry)
        case .depth:
            output.overlay = depthMap(head)
        }
    }

    // MARK: Boxes

    struct Candidate {
        var detection: Detection
        var anchor: Int
        /// Box in model-input pixels, for mask cropping.
        var inputBox: CGRect
    }

    /// Picks the best class per anchor, thresholds, then runs class-aware NMS.
    private func boxes(_ head: Tensor, classes: Int, geometry: Geometry, rotated: Bool = false) -> [Candidate] {
        let anchors = head.shape[2]
        var best = [Float](repeating: 0, count: anchors)
        var bestClass = [Int](repeating: 0, count: anchors)
        head.values.withUnsafeBufferPointer { values in
            for c in 0..<classes {
                let row = values.baseAddress! + (4 + c) * anchors
                for a in 0..<anchors where row[a] > best[a] {
                    best[a] = row[a]
                    bestClass[a] = c
                }
            }
        }
        let candidates = (0..<anchors).filter { best[$0] >= confidence }.map { a -> Candidate in
            let value = { head.values[$0 * anchors + a] }
            let (cx, cy, w, h) = (value(0), value(1), value(2), value(3))
            var detection = Detection(
                box: geometry.rect(cx: cx, cy: cy, w: w, h: h), confidence: best[a], classIndex: bestClass[a])
            if rotated { detection.angle = value(4 + classes) }
            let inputBox = CGRect(x: CGFloat(cx - w / 2), y: CGFloat(cy - h / 2), width: CGFloat(w), height: CGFloat(h))
            return Candidate(detection: detection, anchor: a, inputBox: inputBox)
        }
        .sorted { $0.detection.confidence > $1.detection.confidence }

        var kept: [Candidate] = []
        for candidate in candidates where kept.count < Self.maxDetections {
            let suppressed = kept.contains {
                $0.detection.classIndex == candidate.detection.classIndex
                    && overlap($0.detection, candidate.detection, rotated: rotated) > iou
            }
            if !suppressed { kept.append(candidate) }
        }
        return kept
    }

    private func overlap(_ a: Detection, _ b: Detection, rotated: Bool) -> Float {
        guard rotated else {
            let inter = a.box.intersection(b.box)
            guard !inter.isNull else { return 0 }
            let i = inter.width * inter.height
            return Float(i / (a.box.width * a.box.height + b.box.width * b.box.height - i))
        }
        guard a.box.insetBy(dx: -a.box.width, dy: -a.box.height).intersects(b.box) else { return 0 }
        let (pa, pb) = (corners(of: a), corners(of: b))
        let i = area(clip(pa, by: pb))
        return Float(i / (area(pa) + area(pb) - i))
    }

    // MARK: Overlays

    /// Colors each pixel by the highest-scoring instance covering it, at prototype resolution, cropped to the frame.
    private func instanceMasks(_ kept: [Candidate], head: Tensor, protos: Tensor, geometry: Geometry) -> CGImage? {
        let (dims, ph, pw) = (protos.shape[1], protos.shape[2], protos.shape[3])
        let (anchors, coefficientRow) = (head.shape[2], head.shape[1] - dims)
        let n = kept.count
        guard n > 0 else { return nil }
        // masks[n, ph*pw] = coefficients[n, dims] x protos[dims, ph*pw]
        var coefficients = [Float](repeating: 0, count: n * dims)
        for (i, candidate) in kept.enumerated() {
            for d in 0..<dims { coefficients[i * dims + d] = head.values[(coefficientRow + d) * anchors + candidate.anchor] }
        }
        var masks = [Float](repeating: 0, count: n * ph * pw)
        vDSP_mmul(coefficients, 1, protos.values, 1, &masks, 1, vDSP_Length(n), vDSP_Length(ph * pw), vDSP_Length(dims))

        let scale = CGFloat(pw) / CGFloat(width)
        let (x0, y0) = (Int((geometry.padX * scale).rounded()), Int((geometry.padY * scale).rounded()))
        let (w, h) = (pw - 2 * x0, ph - 2 * y0)
        let regions = kept.map { $0.inputBox.applying(CGAffineTransform(scaleX: scale, y: scale)) }
        var rgba = [UInt8](repeating: 0, count: max(w * h, 0) * 4)
        for y in 0..<max(h, 0) {
            for x in 0..<w {
                let (px, py) = (x + x0, y + y0)
                let point = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
                guard let i = (0..<n).first(where: { regions[$0].contains(point) && masks[$0 * ph * pw + py * pw + px] > -1 })
                else { continue }
                let probability = 1 / (1 + exp(-masks[i * ph * pw + py * pw + px]))
                let alpha = min(max((probability - 0.35) / 0.3, 0), 1) * 0.55
                let (r, g, b) = Palette.classes[kept[i].detection.classIndex % Palette.classes.count]
                let o = (y * w + x) * 4
                rgba[o] = UInt8(Float(r) * alpha)
                rgba[o + 1] = UInt8(Float(g) * alpha)
                rgba[o + 2] = UInt8(Float(b) * alpha)
                rgba[o + 3] = UInt8(255 * alpha)
            }
        }
        return makeImage(rgba: rgba, width: w, height: h)
    }

    /// Per-pixel argmax colored with the Cityscapes palette, cropped to the frame.
    private func classMap(_ logits: Tensor, geometry: Geometry) -> CGImage? {
        let (classes, mh, mw) = (logits.shape[1], logits.shape[2], logits.shape[3])
        let plane = mh * mw
        var best = [Float](repeating: -.infinity, count: plane)
        var bestClass = [UInt8](repeating: 0, count: plane)
        logits.values.withUnsafeBufferPointer { values in
            for c in 0..<classes {
                let row = values.baseAddress! + c * plane
                for p in 0..<plane where row[p] > best[p] {
                    best[p] = row[p]
                    bestClass[p] = UInt8(c)
                }
            }
        }
        let (x0, y0) = (Int(geometry.padX.rounded()), Int(geometry.padY.rounded()))
        let (w, h) = (mw - 2 * x0, mh - 2 * y0)
        let alpha: Float = 0.5
        var rgba = [UInt8](repeating: 0, count: max(w * h, 0) * 4)
        for y in 0..<max(h, 0) {
            for x in 0..<w {
                let (r, g, b) = Palette.cityscapes[Int(bestClass[(y + y0) * mw + x + x0]) % Palette.cityscapes.count]
                let o = (y * w + x) * 4
                rgba[o] = UInt8(Float(r) * alpha)
                rgba[o + 1] = UInt8(Float(g) * alpha)
                rgba[o + 2] = UInt8(Float(b) * alpha)
                rgba[o + 3] = UInt8(255 * alpha)
            }
        }
        return makeImage(rgba: rgba, width: w, height: h)
    }

    /// Turbo-colored depth, near is warm. The depth input is stretched, so the map covers the whole frame.
    private func depthMap(_ depth: Tensor) -> CGImage? {
        let (mh, mw) = (depth.shape[depth.shape.count - 2], depth.shape[depth.shape.count - 1])
        let (low, high) = (vDSP.minimum(depth.values), vDSP.maximum(depth.values))
        guard high > low, low.isFinite, high.isFinite else { return nil }
        var rgba = [UInt8](repeating: 255, count: mw * mh * 4)
        for (i, value) in depth.values.enumerated() {
            let (r, g, b) = Palette.turbo(1 - (value - low) / (high - low))
            rgba[i * 4] = r
            rgba[i * 4 + 1] = g
            rgba[i * 4 + 2] = b
        }
        return makeImage(rgba: rgba, width: mw, height: mh)
    }
}

// MARK: Rotated box geometry

/// Corners of an oriented box, clockwise in top-left image space.
public nonisolated func corners(of detection: Detection) -> [CGPoint] {
    let (c, s) = (CGFloat(cos(detection.angle)), CGFloat(sin(detection.angle)))
    let (hw, hh) = (detection.box.width / 2, detection.box.height / 2)
    return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
        CGPoint(x: detection.box.midX + dx * c - dy * s, y: detection.box.midY + dx * s + dy * c)
    }
}

private nonisolated func area(_ polygon: [CGPoint]) -> CGFloat {
    guard polygon.count > 2 else { return 0 }
    return abs(polygon.indices.reduce(0) { sum, i in
        let (a, b) = (polygon[i], polygon[(i + 1) % polygon.count])
        return sum + a.x * b.y - b.x * a.y
    }) / 2
}

/// Sutherland–Hodgman clip of `subject` by the convex polygon `clipper`.
private nonisolated func clip(_ subject: [CGPoint], by clipper: [CGPoint]) -> [CGPoint] {
    func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat { (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) }
    let orientation: CGFloat = cross(clipper[0], clipper[1], clipper[2]) >= 0 ? 1 : -1
    var output = subject
    for i in clipper.indices where !output.isEmpty {
        let (a, b) = (clipper[i], clipper[(i + 1) % clipper.count])
        let input = output
        output = []
        for j in input.indices {
            let (p, q) = (input[j], input[(j + 1) % input.count])
            let (dp, dq) = (cross(a, b, p) * orientation, cross(a, b, q) * orientation)
            if dp >= 0 { output.append(p) }
            if (dp >= 0) != (dq >= 0) {
                let t = dp / (dp - dq)
                output.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
            }
        }
    }
    return output
}
