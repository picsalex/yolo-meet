import AppKit
import PenLink
import SpriteKit

/// Pictures to place on the whiteboard, picked from the pen app's sticker list (`Drawing.place(sticker:)`). Each kind
/// draws itself as an image in the whiteboard's ink, so it stays sharp at any zoom. A kind can offer actions of its own
/// (`StickerContent.actions`), shown in the menu of the sticker's toolbar on the pad; its content is drawn again after
/// one.
enum Stickers {
    /// The kinds, in the list's order: what the pad shows, and how to make one.
    static let all: [(info: StickerInfo, make: () -> any StickerContent)] = [
        (
            StickerInfo(id: "neural-network", title: "Neural network", symbol: "point.3.connected.trianglepath.dotted"),
            { NetworkSticker() }
        )
    ]

    static func make(_ id: String) -> (any StickerContent)? { all.first { $0.info.id == id }?.make() }
}

/// What a sticker shows.
protocol StickerContent: AnyObject {
    /// Its size, in sticker points: ink points on stage when it was placed.
    var size: CGSize { get }
    /// Draws it, the origin at its bottom left: lines and text in `ink`, shapes filled with `paper`.
    func draw(in context: CGContext, ink: CGColor, paper: CGColor)
    /// What it can do, besides being moved, locked, duplicated and deleted.
    var actions: [StickerAction] { get }
    /// Does one of its `actions`, by id: it is drawn again after.
    func perform(_ action: String)
    /// A copy of it as it is now, for Duplicate.
    func copy() -> any StickerContent
}

extension StickerContent {
    var actions: [StickerAction] { [] }
    func perform(_ action: String) {}
}

/// A sticker on the whiteboard: its content as an image, placed on the board at the size it had on stage then.
final class Sticker {
    /// The most pixels for a sticker's image: zoomed far in, it is drawn a little softer, not larger.
    static let pixels: CGFloat = 4_000_000

    let node = SKSpriteNode()
    let content: any StickerContent
    /// When it was placed, among the board's strokes: undo takes the newest. It names it for the pad, too.
    let order: Int
    /// It can't be moved, deleted, undone or cleared until it is unlocked.
    var isLocked = false
    /// Its content was changed: it is drawn again on the next frame.
    var changed = true
    private let ink: CGColor
    private let paper: CGColor
    /// Pixels per sticker point of its image.
    private var scale: CGFloat = 0

    /// `center` on the board, and `size`: board points per sticker point.
    init(_ content: any StickerContent, at center: CGPoint, size: CGFloat, order: Int, ink: NSColor) {
        (self.content, self.order) = (content, order)
        (self.ink, paper) = (ink.cgColor, NSColor.white.cgColor)
        node.size = content.size
        node.setScale(size)
        node.position = center
    }

    /// Where it is on the board.
    var frame: CGRect { node.frame }

    /// Draws its image again when its content changed, or when the board's pixels per point changed enough to show.
    func redraw(unit: CGFloat) {
        let size = content.size
        let wanted = min(unit * node.xScale, (Self.pixels / (size.width * size.height)).squareRoot())
        guard wanted > 0, changed || abs(wanted - scale) > 0.2 * scale else { return }
        (changed, scale) = (false, wanted)
        let (width, height) = (Int((size.width * scale).rounded(.up)), Int((size.height * scale).rounded(.up)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        content.draw(in: context, ink: ink, paper: paper)
        guard let image = context.makeImage() else { return }
        // A new texture keeps the sprite's size. Setting `size` here would undo its scale: SpriteKit's size is the
        // scaled one.
        node.texture = SKTexture(cgImage: image)
    }
}

extension CGContext {
    /// Draws `text` centered on `center`, in `font` and `color`.
    func drawText(_ text: String, centeredOn center: CGPoint, font: NSFont, color: CGColor) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, self)
    }
}
