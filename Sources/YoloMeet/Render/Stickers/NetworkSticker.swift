import AppKit
import PenLink

/// A small neural network: two inputs, a hidden layer of four neurons and one output, every neuron joined by an arrow
/// to each one of the next layer. Each arrow is as thick as its weight is large and shows it; each neuron after the
/// inputs shows its bias. The values are random, made when it is placed and again with Randomize values.
final class NetworkSticker: StickerContent {
    let size = CGSize(width: 470, height: 330)
    /// Where the neurons are, layer by layer, in sticker points.
    let layers: [[CGPoint]] = [
        [235, 95].map { CGPoint(x: 45, y: $0) },
        [282, 204, 126, 48].map { CGPoint(x: 265, y: $0) },
        [CGPoint(x: 425, y: 165)],
    ]
    /// The weight of each arrow, between a layer (index) and the next one: `[from][to]`.
    var weights: [[[Double]]]
    /// The bias of each neuron after the inputs, by layer (the inputs' are empty).
    var biases: [[Double]]

    private static let radius: CGFloat = 28
    /// How far before the neuron it points at each weight shows, by the layer and the neuron its arrow leaves: the
    /// arrows leaving the inputs cross, so each input's values are a column of their own, near the neurons they point
    /// at, where its arrows are apart.
    private static let before: [[CGFloat]] = [[70, 130], [95, 95, 95, 95]]

    let actions = [StickerAction(id: "randomize", title: "Randomize values", symbol: "dice")]

    init() {
        (weights, biases) = ([], [])
        randomize()
    }

    /// New random values, between -1 and 1 to two decimals.
    private func randomize() {
        func random() -> Double { (Double.random(in: -1...1) * 100).rounded() / 100 }
        weights = zip(layers, layers.dropFirst()).map { from, to in from.map { _ in to.map { _ in random() } } }
        biases = layers.enumerated().map { index, layer in index == 0 ? [] : layer.map { _ in random() } }
    }

    func perform(_ action: String) { if action == "randomize" { randomize() } }

    func copy() -> any StickerContent {
        let copy = NetworkSticker()
        (copy.weights, copy.biases) = (weights, biases)
        return copy
    }

    func draw(in context: CGContext, ink: CGColor, paper: CGColor) {
        let font = NSFont(name: "GeistMono-Medium", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineCap(.round)
        // The arrows, under the neurons, from edge to edge.
        var labels: [(text: String, at: CGPoint)] = []
        for (layer, (from, to)) in zip(layers, layers.dropFirst()).enumerated() {
            for (i, start) in from.enumerated() {
                for (j, end) in to.enumerated() {
                    let weight = weights[layer][i][j]
                    let width = 1.5 + 4.5 * CGFloat(abs(weight))
                    let (dx, dy) = (end.x - start.x, end.y - start.y)
                    let length = hypot(dx, dy)
                    let (ux, uy) = (dx / length, dy / length)
                    let head = 9 + 1.6 * width
                    let tail = CGPoint(x: start.x + ux * Self.radius, y: start.y + uy * Self.radius)
                    let tip = CGPoint(x: end.x - ux * (Self.radius + 2), y: end.y - uy * (Self.radius + 2))
                    let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
                    context.setLineWidth(width)
                    context.move(to: tail)
                    context.addLine(to: base)
                    context.strokePath()
                    // The head: wider than the line, pointing at the neuron.
                    let side = head * 0.55
                    context.move(to: tip)
                    context.addLine(to: CGPoint(x: base.x - uy * side, y: base.y + ux * side))
                    context.addLine(to: CGPoint(x: base.x + uy * side, y: base.y - ux * side))
                    context.closePath()
                    context.fillPath()
                    let before = Self.before[layer][i]
                    labels.append((Self.text(weight), CGPoint(x: end.x - ux * before, y: end.y - uy * before)))
                }
            }
        }
        // The neurons: the inputs named, the others with their bias.
        context.setLineWidth(2.5)
        for (layer, neurons) in layers.enumerated() {
            for (index, center) in neurons.enumerated() {
                let circle = CGRect(
                    x: center.x - Self.radius, y: center.y - Self.radius, width: 2 * Self.radius,
                    height: 2 * Self.radius)
                context.setFillColor(paper)
                context.fillEllipse(in: circle)
                context.strokeEllipse(in: circle)
                if layer == 0 {
                    // x, with its number under the line.
                    let small =
                        NSFont(name: "GeistMono-Medium", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
                    let big =
                        NSFont(name: "GeistMono-Medium", size: 17) ?? .monospacedSystemFont(ofSize: 17, weight: .medium)
                    context.drawText("x", centeredOn: CGPoint(x: center.x - 4, y: center.y + 1), font: big, color: ink)
                    context.drawText(
                        "\(index + 1)", centeredOn: CGPoint(x: center.x + 6, y: center.y - 5), font: small, color: ink)
                } else {
                    context.drawText(Self.text(biases[layer][index]), centeredOn: center, font: font, color: ink)
                }
            }
        }
        // The weights, each on a patch of paper over its arrow.
        for label in labels {
            let width = CGFloat(label.text.count) * 8 + 8
            let patch = CGRect(x: label.at.x - width / 2, y: label.at.y - 9, width: width, height: 18)
            context.setFillColor(paper)
            context.addPath(CGPath(roundedRect: patch, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.fillPath()
            context.drawText(label.text, centeredOn: label.at, font: font, color: ink)
        }
    }

    /// A value with two decimals and a true minus sign.
    private static func text(_ value: Double) -> String {
        (value < 0 ? "−" : "") + String(format: "%.2f", abs(value))
    }
}
