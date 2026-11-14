import Foundation

/// The link between yolo-meet (the host) and the iPad pen app (the pad): the pad sends its Apple Pencil's strokes, the
/// host draws them on the stage (`Drawing`) and sends the stage's picture back, so the pad shows what is drawn on.
/// They find each other with Bonjour, on the network they share or straight between the devices when they share none,
/// so neither needs the internet.
public nonisolated enum PenLink {
    /// The Bonjour service the host advertises and the pad looks for, and the name it advertises it under (Bonjour
    /// adds a number when two Macs nearby have it on).
    public static let service = "_yolomeet-pen._tcp"
    public static let serviceName = "yolo-meet"
    /// The link's version, in each end's first frame: ends of different versions don't connect, and the pad says so.
    public static let version: UInt8 = 1
    /// The pad's surface in ink points: the stage at unit 1, origin bottom-left.
    public static let size = CGSize(width: 1280, height: 720)

    /// How wide the line is for a press of `force` (1 is an average press), as a factor of the ink's width.
    public static func press(force: Double) -> Double { min(max(0.35 + 0.65 * force, 0.35), 2.2) }
}

/// The ink's settings: the same in the host's panel and on the pad, whichever changes them.
public nonisolated struct InkSettings: Codable, Sendable, Equatable {
    /// The widths a line can have, in ink points.
    public static let widths = 2.0...16.0
    /// How long fading ink can stay before it fades, in seconds.
    public static let stays = 1.0...30.0

    /// The next strokes' color, as hex.
    public var color: String
    /// The next strokes' width, in ink points.
    public var width: Double
    /// Strokes fade out once they have stayed `fadeAfter` seconds; otherwise they stay until they are removed.
    public var fades: Bool
    public var fadeAfter: Double
    /// The pen and the mouse erase instead of drawing: a stroke they touch leaves the stage.
    public var erases: Bool

    /// How far around its middle the eraser reaches, in ink points: it grows with the line.
    public var eraserRadius: Double { 8 + width }

    public init(color: String, width: Double, fades: Bool, fadeAfter: Double, erases: Bool) {
        (self.color, self.width, self.fades, self.fadeAfter, self.erases) = (color, width, fades, fadeAfter, erases)
    }
}

/// From the pad to the host. Points are in ink points.
public nonisolated enum PadMessage: Codable, Sendable, Equatable {
    case hello(name: String)
    /// The pen is over the pad without touching it: `height` is 0 at the glass and 1 at the farthest it is seen.
    case hover(x: Double, y: Double, height: Double)
    case hoverEnded
    /// The pen touched down: a new stroke, named `id` by the pad, or the eraser's when the ink's settings say it
    /// erases. `force` is 1 for an average press.
    case down(id: Int, x: Double, y: Double, force: Double)
    case move(x: Double, y: Double, force: Double)
    case up
    case undo
    case clear
    /// The pad changed the ink's settings: the host keeps what its panel could set, and answers if that differs.
    case set(InkSettings)
}

/// From the host to the pad.
public nonisolated enum HostMessage: Codable, Sendable, Equatable {
    /// The Mac's name, sent first: only a pad that has the code hears it (Bonjour shows the app's name).
    case hello(name: String)
    /// The ink's settings and the colors to pick from (hex): sent on connecting and whenever the host changes them.
    case settings(InkSettings, colors: [String])
    /// The pad's strokes still on stage, sent on connecting: the pad forgets its others.
    case ink(ids: [Int])
    /// Strokes of the pad's that left the stage: undone, cleared or faded.
    case removed(ids: [Int])
    /// The stage as it was just drawn, as a JPEG. It shows the pad's stroke `through` whole, and those before it:
    /// the latest that was finished when the picture was taken, if any.
    case picture(jpeg: Data, through: Int?)
}

/// A message that crosses the link (`PenFrames`): most go as JSON, and the stage's picture as its JPEG, as is.
public nonisolated protocol PenMessage: Codable, Sendable {
    /// Who sends this kind of message: its direction's key is made for it (`PenSession`).
    static var sender: String { get }
    /// The longest frame of these an end reads: a longer one breaks the link.
    static var largestFrame: Int { get }
    /// The picture this message is, if it is one: its JPEG, and the pad's stroke it shows whole.
    var pictureFrame: (jpeg: Data, through: Int?)? { get }
    /// The message a picture frame carries; nil for an end that is never sent pictures.
    init?(pictureFrame jpeg: Data, through: Int?)
}

nonisolated extension PadMessage: PenMessage {
    public static let sender = "pad"
    /// The pad's messages are a few dozen bytes: the host reads nothing much longer.
    public static let largestFrame = 64 << 10
    public var pictureFrame: (jpeg: Data, through: Int?)? { nil }
    public init?(pictureFrame jpeg: Data, through: Int?) { nil }
}

nonisolated extension HostMessage: PenMessage {
    public static let sender = "host"
    /// The stage's pictures are about 100 KB at 720p, a few hundred at most.
    public static let largestFrame = 16 << 20
    public var pictureFrame: (jpeg: Data, through: Int?)? {
        if case let .picture(jpeg, through) = self { (jpeg, through) } else { nil }
    }
    public init?(pictureFrame jpeg: Data, through: Int?) { self = .picture(jpeg: jpeg, through: through) }
}

/// Messages as frames: a byte for the kind, the length in four bytes (big-endian), then the message. A picture is
/// its JPEG after the stroke it shows (four bytes, -1 for none): neither base64 nor text to parse, at 20 a second. On
/// the link, a message's frame is itself sealed in a frame (`PenSession`), after each end's key.
public nonisolated struct PenFrames: Sendable {
    enum Kind: UInt8 {
        case json = 0, picture = 1
        /// An end's key for the connection (`PenSession`): the first frame each way.
        case key = 2
        /// A message's frame, sealed.
        case sealed = 3
    }
    /// The longest frame by default: a longer one means the stream is broken, and nothing after it can be read.
    public static let limit = 16 << 20
    private static let header = 5
    private let longest: Int
    private var buffer = Data()
    /// A frame was out of bounds: the link should be closed.
    public private(set) var isBroken = false

    /// `longest`: the longest frame read.
    public init(longest: Int = PenFrames.limit) { self.longest = longest }

    public static func frame(_ message: some PenMessage) -> Data {
        guard let picture = message.pictureFrame else { return frame(.json, (try? JSONEncoder().encode(message)) ?? Data()) }
        var payload = Data(capacity: 4 + picture.jpeg.count)
        withUnsafeBytes(of: Int32(clamping: picture.through ?? -1).bigEndian) { payload.append(contentsOf: $0) }
        payload.append(picture.jpeg)
        return frame(.picture, payload)
    }

    static func frame(_ kind: Kind, _ payload: Data) -> Data { frame(kind: kind.rawValue, payload) }

    static func frame(kind: UInt8, _ payload: Data) -> Data {
        var data = Data(capacity: header + payload.count)
        data.append(kind)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// The frames completed by `data`, in order: their kind and what they carry.
    mutating func split(_ data: Data) -> [(kind: UInt8, payload: Data)] {
        guard !isBroken else { return [] }
        buffer.append(data)
        var frames: [(kind: UInt8, payload: Data)] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= Self.header {
            let length = (1...4).reduce(0) { $0 << 8 | Int(buffer[start + $1]) }
            guard length <= longest else {
                (isBroken, buffer) = (true, Data())
                return frames
            }
            let end = start + Self.header + length
            guard end <= buffer.endIndex else { break }  // the rest of it hasn't arrived
            frames.append((buffer[start], Data(buffer[(start + Self.header)..<end])))
            start = end
        }
        buffer.removeSubrange(buffer.startIndex..<start)  // once a read, not once a frame
        return frames
    }

    /// The message a frame carries, if it is one of `Message`'s.
    static func message<Message: PenMessage>(kind: UInt8, payload: Data, as type: Message.Type = Message.self) -> Message? {
        switch Kind(rawValue: kind) {
        case .json:
            return try? JSONDecoder().decode(type, from: payload)
        case .picture where payload.count >= 4:
            let through = Int(Int32(bitPattern: payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }))
            return Message(pictureFrame: Data(payload.dropFirst(4)), through: through < 0 ? nil : through)
        default:
            return nil  // not a message, or a kind this end doesn't know
        }
    }

    /// The message in one whole frame (e.g. one just unsealed), if it is one of `Message`'s.
    static func message<Message: PenMessage>(inFrame frame: Data, as type: Message.Type = Message.self) -> Message? {
        var frames = PenFrames(longest: Message.largestFrame)
        guard let only = frames.split(frame).first, frames.buffer.isEmpty else { return nil }
        return message(kind: only.kind, payload: only.payload, as: type)
    }

    /// The messages completed by `data`, in order, from frames that aren't sealed. Frames that aren't a `Message` are
    /// skipped.
    public mutating func take<Message: PenMessage>(_ data: Data, as type: Message.Type = Message.self) -> [Message] {
        split(data).compactMap { Self.message(kind: $0.kind, payload: $0.payload, as: type) }
    }
}
