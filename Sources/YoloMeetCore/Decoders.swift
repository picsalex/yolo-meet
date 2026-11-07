import Accelerate
import CoreGraphics

/// Decoders for the raw (non end-to-end) Ultralytics Core AI heads:
/// - detect `[1, 4+nc, A]`, segment `[1, 4+nc+32, A]` + protos `[1, 32, 160, 160]`, pose `[1, 4+1+K*3, A]`,
///   obb `[1, 4+nc+1, A]` — boxes are center xywh in model-input pixels, scores are already sigmoid-activated.
/// - classify `[1, nc]` probabilities, semantic `[1, nc, H, W]` logits, depth `[1, 1, H, W]`.
/// RF-DETR outputs are decoded by `decodeDETR`.
nonisolated extension YOLOModel {
    static let maxDetections = 100

    func decode(_ tensors: [Tensor], geometry: Geometry, into output: inout ModelOutput) {
        guard !isDETR else { return decodeDETR(tensors, geometry: geometry, into: &output) }
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
        case .hand, .face:
            break  // MediaPipe and Apple Vision tasks, decoded by their own models
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
        // Best score per anchor, one vectorized max per class row; the class is looked up only for anchors that pass.
        var best = [Float](repeating: -.infinity, count: anchors)
        head.values.withUnsafeBufferPointer { values in
            best.withUnsafeMutableBufferPointer { best in
                for c in 0..<classes {
                    vDSP_vmax(best.baseAddress!, 1, values.baseAddress! + (4 + c) * anchors, 1, best.baseAddress!, 1, vDSP_Length(anchors))
                }
            }
        }
        let candidates = (0..<anchors).filter { best[$0] >= confidence }.map { a -> Candidate in
            let value = { head.values[$0 * anchors + a] }
            let (cx, cy, w, h) = (value(0), value(1), value(2), value(3))
            let classIndex = (0..<classes).first { value(4 + $0) == best[a] } ?? 0
            var detection = Detection(
                box: geometry.rect(cx: cx, cy: cy, w: w, h: h), confidence: best[a], classIndex: classIndex)
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

    /// YOLO instance masks: prototype masks weighted by each detection's coefficients, cropped to the frame.
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
        return paintInstances(kept, masks: masks, width: pw, height: ph, scale: scale, crop: (x0, y0))
    }

    /// Colors each pixel by the highest-scoring instance whose box covers it. `masks` holds one `width x height` logit
    /// map per candidate in model-input space scaled by `scale`; `crop` trims the letterbox padding. `kept` is sorted
    /// by score, so painting each box in reverse lets the higher score win.
    private func paintInstances(
        _ kept: [Candidate], masks: [Float], width pw: Int, height ph: Int, scale: CGFloat, crop: (x: Int, y: Int)
    ) -> CGImage? {
        let (w, h) = (pw - 2 * crop.x, ph - 2 * crop.y)
        guard w > 0, h > 0 else { return nil }
        let palette = isDETR ? Palette.roboflow : Palette.ultralytics  // each vendor's annotation colors
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for (i, candidate) in kept.enumerated().reversed() {
            // Pixels whose centers are in the box, within the crop.
            let region = candidate.inputBox.applying(CGAffineTransform(scaleX: scale, y: scale))
            let xs = max(Int((region.minX - 0.5).rounded(.up)), crop.x)..<min(Int((region.maxX - 0.5).rounded(.up)), crop.x + w)
            let ys = max(Int((region.minY - 0.5).rounded(.up)), crop.y)..<min(Int((region.maxY - 0.5).rounded(.up)), crop.y + h)
            guard !xs.isEmpty, !ys.isEmpty else { continue }
            let (r, g, b) = palette[candidate.detection.classIndex % palette.count]
            for py in ys {
                for px in xs {
                    let logit = masks[i * ph * pw + py * pw + px]
                    guard logit > -1 else { continue }
                    let alpha = min(max((1 / (1 + exp(-logit)) - 0.35) / 0.3, 0), 1) * 0.55
                    let o = ((py - crop.y) * w + px - crop.x) * 4
                    rgba[o] = UInt8(Float(r) * alpha)
                    rgba[o + 1] = UInt8(Float(g) * alpha)
                    rgba[o + 2] = UInt8(Float(b) * alpha)
                    rgba[o + 3] = UInt8(255 * alpha)
                }
            }
        }
        return makeImage(rgba: rgba, width: w, height: h)
    }

    // MARK: RF-DETR

    /// RF-DETR outputs, by name: `dets [1, Q, 4]` normalized center xywh, `labels [1, Q, C]` logits indexed by class id,
    /// plus `masks [1, Q, h, w]` logits or `keypoints [1, Q, C*K, D]` (normalized x, y, visibility logit, ...).
    /// Queries are already one per object, so there is no NMS.
    private func decodeDETR(_ tensors: [Tensor], geometry: Geometry, into output: inout ModelOutput) {
        let named = Dictionary(uniqueKeysWithValues: zip(outputNames, tensors))
        guard let boxes = named["dets"], let logits = named["labels"] else { return }
        let (queries, classes) = (logits.shape[1], logits.shape[2])
        let (w, h) = (Float(width), Float(height))
        var kept: [Candidate] = []
        for q in 0..<queries {
            let row = logits.values[(q * classes)..<((q + 1) * classes)]
            guard let best = row.indices.max(by: { row[$0] < row[$1] }) else { continue }
            let score = 1 / (1 + exp(-row[best]))
            guard score >= confidence else { continue }
            let b = boxes.values[(q * 4)..<(q * 4 + 4)].map { $0 }
            let (cx, cy, bw, bh) = (b[0] * w, b[1] * h, b[2] * w, b[3] * h)
            kept.append(Candidate(
                detection: Detection(
                    box: geometry.rect(cx: cx, cy: cy, w: bw, h: bh), confidence: score, classIndex: best - q * classes),
                anchor: q,
                inputBox: CGRect(x: CGFloat(cx - bw / 2), y: CGFloat(cy - bh / 2), width: CGFloat(bw), height: CGFloat(bh))))
        }
        kept = Array(kept.sorted { $0.detection.confidence > $1.detection.confidence }.prefix(Self.maxDetections))

        if let keypoints = named["keypoints"] {
            let (slots, dims) = (keypoints.shape[2], keypoints.shape[3])
            let perClass = slots / classes
            for i in kept.indices {
                let base = (kept[i].anchor * slots + kept[i].detection.classIndex * perClass) * dims
                kept[i].detection.keypoints = (0..<perClass).map { k in
                    let v = { keypoints.values[base + k * dims + $0] }
                    return Keypoint(point: geometry.point(v(0) * w, v(1) * h), confidence: 1 / (1 + exp(-v(2))))
                }
            }
        }
        output.detections = kept.map(\.detection)

        if let masks = named["masks"], !kept.isEmpty {
            let (mh, mw) = (masks.shape[2], masks.shape[3])
            let plane = mh * mw
            var gathered = [Float](repeating: 0, count: kept.count * plane)
            for (i, candidate) in kept.enumerated() {
                gathered.replaceSubrange(
                    (i * plane)..<((i + 1) * plane), with: masks.values[(candidate.anchor * plane)..<((candidate.anchor + 1) * plane)])
            }
            output.overlay = paintInstances(
                kept, masks: gathered, width: mw, height: mh, scale: CGFloat(mw) / CGFloat(width), crop: (0, 0))
        }
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

    /// Depth in the Ultralytics gradient, near is Neon Pink. The depth input is stretched, so the map covers the frame.
    private func depthMap(_ depth: Tensor) -> CGImage? {
        let (mh, mw) = (depth.shape[depth.shape.count - 2], depth.shape[depth.shape.count - 1])
        let (low, high) = (vDSP.minimum(depth.values), vDSP.maximum(depth.values))
        guard high > low, low.isFinite, high.isFinite else { return nil }
        // Gradient step per pixel: 0 for the farthest, 255 for the nearest.
        let steps = vDSP.multiply(255 / (high - low), vDSP.add(-low, depth.values))
        let gradient = Palette.ultralyticsGradient
        var rgba = [UInt8](repeating: 255, count: mw * mh * 4)
        for (i, step) in steps.enumerated() {
            let (r, g, b) = gradient[255 - Int(step.rounded())]
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
