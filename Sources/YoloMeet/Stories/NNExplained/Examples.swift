import AppKit
import simd

extension NetworkLayout {
    /// The client's grayscale picture (drawn after it, `GrayPicture.golfClub`): what it shows and its real size.
    static let clientPicture = (
        name: "Golf club", width: GrayPicture.golfClubSize.width, height: GrayPicture.golfClubSize.height
    )

    /// `grayscale` with a client's grayscale picture on its right, facing the viewer: the gray layer steps aside to
    /// the left, so the two are centered together, and the particles of the layers that faded away (black, unseen)
    /// fly over at once, lighting up on the way, as the picture: a particle per pixel of it (fewer than its real
    /// ones), with its real size along its sides.
    static func grayscaleExample(after grayscale: NetworkLayout) -> NetworkLayout {
        let client = clientPicture
        let layout = NetworkLayout(
            title: grayscale.title, subtitle: "\(client.width) × \(client.height) × 1 value · a client's picture",
            neurons: [], synapses: [], neuronSize: 0.02, restingTilt: grayscale.restingTilt)
        (layout.restingTurn, layout.base) = (grayscale.restingTurn, grayscale.base)
        // In the view at rest (x right, y up, as on stage): the layer then the picture, level with it, centered.
        let view = KeyTurn.rotation(tilt: layout.restingTilt, turn: layout.restingTurn)
        let facing = { (x: Float, y: Float) in view.inverse.act([x, y, 0]) }
        let layer = grayscale.outline.map { view.act($0) }
        let middle = ((layer.map(\.y).min() ?? 0) + (layer.map(\.y).max() ?? 0)) / 2
        let height: Float = 1.5
        let width = height * Float(client.width) / Float(client.height)
        let between: Float = 0.85  // clear of the layer, with room for the picture's height's label
        let edges = (left: layer.map(\.x).min() ?? 0, right: layer.map(\.x).max() ?? 0)
        let total = edges.right - edges.left + between + width
        let aside = facing(-total / 2 - edges.left, 0)  // how far the layer moves
        let left = total / 2 - width
        let (right, top, bottom) = (left + width, middle + height / 2, middle - height / 2)
        layout.outline =
            grayscale.outline.map { $0 + aside }
            + [facing(left, bottom), facing(right, top), facing(left, top), facing(right, bottom)]
        // Its width under it, its height on its left, and what it is under them.
        let gap: Float = 0.08
        layout.dimensions = [
            ("\(client.width) px", facing(left, bottom - gap), facing(right, bottom - gap)),
            ("\(client.height) px", facing(left - gap, top), facing(left - gap, bottom)),
        ]
        layout.headers =
            grayscale.headers.map { ($0.text, $0.point + aside, $0.members) }
            + [(client.name, facing(left + width / 2, bottom - 0.32), [])]
        guard let from = grayscale.shape else { return layout }
        // The unseen particles: a pixel each, row by row from the top (the few left over on random pixels).
        let free = from.points.indices.filter { from.colors[$0] == .zero }
        let rows = Int((Float(free.count) * Float(client.height) / Float(client.width)).squareRoot())
        let columns = free.count / max(rows, 1)
        let picture = GrayPicture.golfClub(width: columns, height: rows)
        var points = from.points.map { $0 + aside }
        var colors = Array(from.colors)
        for (k, i) in free.enumerated() {
            let p = k < columns * rows ? k : Int.random(in: 0..<columns * rows)
            // Anywhere on its pixel: an even grid of points beats against the screen's.
            let x = (Float(p % columns) + .random(in: 0.1...0.9)) / Float(columns)
            let y = (Float(p / columns) + .random(in: 0.1...0.9)) / Float(rows)
            points[i] = view.inverse.act([left + x * width, top - y * height, .random(in: -0.004...0.004)])
            // Lifted: the picture is dark but for the club (light adds up from black).
            colors[i] = SIMD3(repeating: 1.7 * pow(picture.values[p], 0.85))
        }
        // No glide to wait for: they spring there as their colors fade in, and the labels show at once.
        layout.shape = ParticleShape(
            points: points, offsets: Array(repeating: .zero, count: points.count), parts: [], colors: colors)
        return layout
    }

    /// The client's wafer (one layer's picture drawn after it, `GrayPicture.wafer`): how many layers it has, and its
    /// defect, which goes through some of them at one place (layers from 0, the place in fractions of a layer from
    /// its top left).
    static let wafer = (layers: 10, defect: (layers: 3...6, at: SIMD2<Float>(0.62, 0.4)))

    /// `bands` made smaller on the left, with the layers of a client's wafer on their right, back to back as the bands
    /// are: ten channels instead of five, seen a little more from above and from the side, so they show one beside
    /// the other. One particle in three stays in its band; the others glide to the wafer, first all its layers
    /// stacked (`prelude`: only the front one shows, as one picture), which then come apart: an exploded view. Each
    /// layer is drawn by its lines (particles where it's bright) in a thin frame, and a defect goes through four of
    /// them at the same place, as they do, with nothing pointing at it.
    static func multispectralExample(of pixels: NetworkLayout, after bands: NetworkLayout) -> NetworkLayout {
        let subtitle = "any number of channels · e.g. the \(wafer.layers) layers of a client's wafer"
        let layout = NetworkLayout(
            title: bands.title, subtitle: subtitle, neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0.3)
        let prelude = NetworkLayout(
            title: bands.title, subtitle: subtitle, neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0.3)
        for each in [layout, prelude] { (each.restingTurn, each.base, each.splits) = (-1, bands.base, true) }
        (prelude.splitsFrom, layout.prelude, layout.splitsFrom) = (bands, prelude, prelude)

        // In the view at rest (x right, y up, as on stage, around the stage's middle: it takes its whole width), each
        // group's layers a step further right, and further back, than the one before.
        let view = KeyTurn.rotation(tilt: layout.restingTilt, turn: layout.restingTurn)
        let facing = { (x: Float, y: Float) in view.inverse.act([x, y, 0]) }
        let back = SIMD3<Float>(0.3125, 0, -1)
        let right = back / view.act(back).x  // a layer's step that shows as one unit to the right
        func fan(_ count: Int, around x: Float, step: Float) -> [SIMD3<Float>] {
            (0..<count).map { facing(x, 0) + right * step * (Float($0) - Float(count - 1) / 2) }
        }
        let bandCount = bands.headers.count
        let cat = (side: Float(0.7), centers: fan(bandCount, around: -2.59, step: 0.3))
        let stack = (side: Float(1.05), middle: Float(0.93), centers: fan(wafer.layers, around: 0.93, step: 0.48))
        let corners = { (center: SIMD3<Float>, side: Float) -> [SIMD3<Float>] in
            ([[-1, -1], [1, 1], [-1, 1], [1, -1]] as [SIMD2<Float>]).map { center + SIMD3($0, 0) * side / 2 }
        }
        let outlines = (
            cat: cat.centers.flatMap { corners($0, cat.side) }, stack: stack.centers.flatMap { corners($0, stack.side) }
        )
        layout.outline = outlines.cat + outlines.stack
        // Each wafer layer's number under it, and how many each group has along a line under it.
        layout.headerSize = 15
        layout.headers = stack.centers.enumerated().map { l, center in
            ("\(l + 1)", center - [0, stack.side / 2 + 0.05, 0], [Int]())
        }
        let floor = layout.outline.map { view.act($0).y }.min() ?? 0
        layout.dimensions = [("\(bandCount) bands", outlines.cat), ("\(wafer.layers) layers", outlines.stack)].map {
            let xs = $0.1.map { view.act($0).x }
            return ($0.0, facing(xs.min() ?? 0, floor - 0.3), facing(xs.max() ?? 0, floor - 0.3))
        }
        guard let picture = pixels.shape, let from = bands.shape else { return layout }

        // The cat: one particle in three stays in its band, on its pixel. Each pixel keeps its brightness in each
        // band (by how many of its particles stay), in a smaller band (denser).
        let (n, cells) = (picture.points.count, pixelCells)
        let stays = { (i: Int) in (i / bandCount) % 3 == 0 }
        let pixelPoints = picture.arrived
        var kept = [Int](repeating: 0, count: cells * cells * bandCount)
        let slots = (0..<n).map { i -> Int in
            let p = pixelPoints[i] / pixelSide
            let column = min(max(Int((p.x + 0.5) * Float(cells)), 0), cells - 1)
            let row = min(max(Int((0.5 - p.y) * Float(cells)), 0), cells - 1)
            let slot = (row * cells + column) * bandCount + i % bandCount
            if stays(i) { kept[slot] += 1 }
            return slot
        }
        let bandSide = pixelSide * bandScale
        let fewer = Float(n) / Float(kept.count) * pow(cat.side / bandSide, 2)  // per pixel and band before, as dense

        // The wafer: each layer's share of the others, where its lines are.
        let image = GrayPicture.wafer()
        let grid = 144
        let layers = (0..<wafer.layers).map { waferLayer($0, of: image, grid: grid) }
        let lit = SIMD3<Float>(0.75, 0.9, 1) * 1.1
        let frame: Float = 0.08  // of a layer's particles, along its edges
        let start = from.arrived
        var (points, stacked) = (start, start)
        var (colors, arrivedColors, stackedColors) = (Array(from.colors), Array(from.colors), Array(from.colors))
        var next = 0
        for i in 0..<n {
            if stays(i) {
                let c = i % bandCount
                points[i] = pixelPoints[i] * (cat.side / pixelSide) + cat.centers[c]
                colors[i] = (from.colors[i] ?? .zero) * fewer / Float(max(kept[slots[i]], 1))
                (stacked[i], arrivedColors[i], stackedColors[i]) = (points[i], colors[i], colors[i])
                continue
            }
            let l = next % wafer.layers
            next += 1
            // A point of the layer by its brightness: a cell of the grid, anywhere in it.
            var cell = Int.random(in: 0..<grid * grid)
            if let total = layers[l].last, total > 0 {
                let cumulative = layers[l]
                let pick = Float.random(in: 0..<total)
                var (low, high) = (0, cumulative.count - 1)
                while low < high {
                    let mid = (low + high) / 2
                    if cumulative[mid] > pick { high = mid } else { low = mid + 1 }
                }
                cell = low
            }
            var x = (Float(cell % grid) + .random(in: 0..<1)) / Float(grid) - 0.5
            var y = 0.5 - (Float(cell / grid) + .random(in: 0..<1)) / Float(grid)
            let onFrame = Float.random(in: 0..<1) < frame
            if onFrame {
                // On one of its four edges.
                let (along, edge) = (Float.random(in: -0.5...0.5), Bool.random() ? Float(0.5) : -0.5)
                (x, y) = Bool.random() ? (along, edge) : (edge, along)
            }
            let onLayer = SIMD3<Float>(x, y, 0) * stack.side
            points[i] = stack.centers[l] + onLayer
            // Stacked, all the layers in one place: only the front one shows (ten would add up to a white blur), the
            // others unseen behind it until they come out.
            stacked[i] = facing(stack.middle, 0) + onLayer + [0, 0, 0.012 * (Float(wafer.layers - 1) / 2 - Float(l))]
            let light = lit * (onFrame ? 0.6 : 1)
            (colors[i], arrivedColors[i], stackedColors[i]) = (light, light, l == 0 ? light : .zero)
        }
        prelude.outline = outlines.cat + corners(facing(stack.middle, 0), stack.side)
        prelude.shape = ParticleShape(
            points: start, offsets: zip(stacked, start).map { $0 - $1 }, parts: [], colors: stackedColors)
        layout.shape = ParticleShape(
            points: stacked, offsets: zip(points, stacked).map { $0 - $1 }, parts: [], colors: colors)
        layout.arrivedColors = ParticleColors(arrivedColors)
        return layout
    }

    /// Layer `l` of the wafer, made from its one picture: a window of it, smaller from one layer to the next (the
    /// first layers of a chip have the finest lines) and turned a quarter turn every other layer (a chip's layers
    /// alternate their lines' direction), with the defect where it goes through the layer. As running totals of
    /// brightness over a `grid` × `grid` (row by row from the top), to pick points where it's bright.
    private static func waferLayer(_ l: Int, of image: GrayPicture, grid: Int) -> [Float] {
        // The window: its side and where its center is, in fractions of the picture (spread over it).
        let side = 0.56 - 0.028 * Float(l)
        let spread: [SIMD2<Float>] = [
            [0.2, 0.6], [0.7, 0.25], [0.45, 0.8], [0.85, 0.4], [0.1, 0.15], [0.6, 0.9], [0.3, 0.55], [0.9, 0.3],
            [0.5, 0.7], [0.15, 0.05],
        ]
        let center = SIMD2<Float>(repeating: side / 2) + spread[l % spread.count] * (1 - side)
        // The defect: a bright blob, irregular, largest in the middle layers, the lines broken around it.
        let through = wafer.defect.layers
        let radius: Float =
            through.contains(l)
            ? 0.075 * sin(.pi * (Float(l - through.lowerBound) + 0.9) / (Float(through.count) + 0.8)) : 0
        let phase = Float(l) * 1.7
        var total: Float = 0
        return (0..<grid * grid).map { cell in
            let at = SIMD2<Float>((Float(cell % grid) + 0.5) / Float(grid), (Float(cell / grid) + 0.5) / Float(grid))
            var d = at - 0.5
            if l % 2 == 1 { d = [-d.y, d.x] }
            let source = (center + d * side) * SIMD2<Float>(Float(image.width), Float(image.height))
            // Its lines: brighter than the dark between them.
            var weight = pow(max(image.at(source.x, source.y) - 0.42, 0) / 0.58, 1.5)
            if radius > 0 {
                let from = at - wafer.defect.at
                let angle = atan2(from.y, from.x)
                let edge = radius * (1 + 0.22 * sin(3 * angle + phase) + 0.12 * sin(5 * angle + 2 * phase))
                let distance = simd_length(from)
                if distance < edge {
                    weight = max(weight, 0.6 - 0.25 * distance / edge)
                } else if distance < edge * 1.6 {
                    weight *= 0.12
                }
            }
            total += weight
            return total
        }
    }
}
