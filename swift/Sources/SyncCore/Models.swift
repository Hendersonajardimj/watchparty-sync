import Foundation

// Wire types for watchparty-sync protocol v1 (docs/PROTOCOL.md).
// All JSON is camelCase, all times are integer milliseconds.

public struct Movie: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var year: Int?
    public var quality: String?
    public var container: String
    public var sizeBytes: Int64
    public var addedAt: Int64

    public init(id: String, title: String, year: Int?, quality: String?, container: String, sizeBytes: Int64, addedAt: Int64) {
        self.id = id
        self.title = title
        self.year = year
        self.quality = quality
        self.container = container
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
    }

    /// "Sample Film (2006)" or just "Sample Film".
    public var displayTitle: String {
        if let year { return "\(title) (\(year))" }
        return title
    }
}

public struct MovieList: Codable, Sendable {
    public var movies: [Movie]
}

public struct Me: Codable, Hashable, Sendable {
    public var userId: String
    public var name: String
}

public struct Health: Codable, Sendable {
    public var ok: Bool
    public var version: String?
}

public struct You: Codable, Hashable, Sendable {
    public var userId: String
    public var name: String
    public var connId: String
}

public enum ParticipantState: String, Codable, Sendable {
    case ready
    case buffering
}

public struct Participant: Codable, Hashable, Sendable, Identifiable {
    public var connId: String
    public var userId: String
    public var name: String
    /// Kept as a raw string so an unexpected server value never breaks decoding of the whole room.
    public var state: String

    public var id: String { connId }
    public var isBuffering: Bool { state == ParticipantState.buffering.rawValue }

    public init(connId: String, userId: String, name: String, state: String) {
        self.connId = connId
        self.userId = userId
        self.name = name
        self.state = state
    }
}

public struct LastAction: Codable, Hashable, Sendable {
    public var by: String
    public var action: String
    public var at: Int64
    /// The connection that caused it; nil for server actions (autoWait, autoResume, ended).
    public var connId: String?

    public init(by: String, action: String, at: Int64, connId: String? = nil) {
        self.by = by
        self.action = action
        self.at = at
        self.connId = connId
    }
}

public struct RoomState: Codable, Hashable, Sendable {
    public var rev: Int64
    public var movie: Movie
    public var playing: Bool
    public var positionMs: Int64
    public var asOfServerTime: Int64
    public var durationMs: Int64?
    public var autoWait: Bool
    public var waiting: [String]
    public var lastAction: LastAction?
    public var participants: [Participant]
    public var startedBy: String
    public var startedAt: Int64

    public init(rev: Int64, movie: Movie, playing: Bool, positionMs: Int64, asOfServerTime: Int64,
                durationMs: Int64?, autoWait: Bool, waiting: [String], lastAction: LastAction?,
                participants: [Participant], startedBy: String, startedAt: Int64) {
        self.rev = rev
        self.movie = movie
        self.playing = playing
        self.positionMs = positionMs
        self.asOfServerTime = asOfServerTime
        self.durationMs = durationMs
        self.autoWait = autoWait
        self.waiting = waiting
        self.lastAction = lastAction
        self.participants = participants
        self.startedBy = startedBy
        self.startedAt = startedAt
    }

    /// PROTOCOL: effective position now = positionMs + (playing ? serverNow - asOfServerTime : 0).
    /// Clamped to [0, durationMs] when the duration is known.
    public func effectivePosition(serverNow: Int64) -> Int64 {
        var pos = positionMs + (playing ? serverNow - asOfServerTime : 0)
        if pos < 0 { pos = 0 }
        if let durationMs, durationMs > 0, pos > durationMs { pos = durationMs }
        return pos
    }

    public func isJoined(connId: String?) -> Bool {
        guard let connId else { return false }
        return participants.contains { $0.connId == connId }
    }
}

// MARK: - Chat

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var movieId: String
    public var userId: String
    public var name: String
    public var text: String
    public var movieMs: Int64?
    public var sentAt: Int64

    public init(id: Int64, movieId: String, userId: String, name: String, text: String, movieMs: Int64?, sentAt: Int64) {
        self.id = id
        self.movieId = movieId
        self.userId = userId
        self.name = name
        self.text = text
        self.movieMs = movieMs
        self.sentAt = sentAt
    }

    /// Rendering hook for future message kinds (GIFs, images in v2). v1 only has text.
    public var body: ChatBody { .text(text) }
}

public enum ChatBody: Hashable, Sendable {
    case text(String)
    // v2: case gif(URL), case image(URL)
}

// MARK: - Server → client

public enum ServerMessage: Sendable, Equatable {
    case welcome(you: You, serverTime: Int64, room: RoomState?)
    case pong(clientTime: Int64, serverTime: Int64)
    case room(RoomState?)
    case chatHistory(movieId: String, messages: [ChatMessage])
    case chatPage(movieId: String, messages: [ChatMessage], hasMore: Bool, before: Int64?)
    case chat(ChatMessage)
    case error(String)
    case unknown(type: String)
}

extension ServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, you, serverTime, room, clientTime, movieId, messages, message, hasMore, before
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                you: try c.decode(You.self, forKey: .you),
                serverTime: try c.decode(Int64.self, forKey: .serverTime),
                room: try c.decodeIfPresent(RoomState.self, forKey: .room)
            )
        case "pong":
            self = .pong(clientTime: try c.decode(Int64.self, forKey: .clientTime),
                         serverTime: try c.decode(Int64.self, forKey: .serverTime))
        case "room":
            self = .room(try c.decodeIfPresent(RoomState.self, forKey: .room))
        case "chatHistory":
            self = .chatHistory(movieId: try c.decode(String.self, forKey: .movieId),
                                messages: try c.decode([ChatMessage].self, forKey: .messages))
        case "chatPage":
            self = .chatPage(movieId: try c.decode(String.self, forKey: .movieId),
                messages: try c.decode([ChatMessage].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore),
                before: try c.decodeIfPresent(Int64.self, forKey: .before))
        case "chat", "generalChat":
            self = .chat(try c.decode(ChatMessage.self, forKey: .message))
        case "error":
            self = .error(try c.decodeIfPresent(String.self, forKey: .message) ?? "Unknown error")
        default:
            self = .unknown(type: type)
        }
    }

    public static func decode(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }
}

// MARK: - Client → server

public enum ClientMessage: Sendable, Equatable {
    case ping(clientTime: Int64)
    case start(movieId: String)
    case join
    case leave
    case play(positionMs: Int64)
    case pause(positionMs: Int64)
    case seek(positionMs: Int64)
    case status(state: ParticipantState, positionMs: Int64, durationMs: Int64?)
    case chat(text: String, movieMs: Int64?)
    case generalChat(text: String)
    case chatPage(movieId: String, before: Int64?)
    case setAutoWait(enabled: Bool)

    public var type: String {
        switch self {
        case .ping: "ping"
        case .start: "start"
        case .join: "join"
        case .leave: "leave"
        case .play: "play"
        case .pause: "pause"
        case .seek: "seek"
        case .status: "status"
        case .chat: "chat"
        case .generalChat: "generalChat"
        case .chatPage: "chatPage"
        case .setAutoWait: "setAutoWait"
        }
    }
}

extension ClientMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, clientTime, movieId, positionMs, state, durationMs, text, movieMs, enabled, before
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .ping(let t):
            try c.encode(t, forKey: .clientTime)
        case .start(let id):
            try c.encode(id, forKey: .movieId)
        case .join, .leave:
            break
        case .play(let p), .pause(let p), .seek(let p):
            try c.encode(p, forKey: .positionMs)
        case .status(let state, let p, let d):
            try c.encode(state, forKey: .state)
            try c.encode(p, forKey: .positionMs)
            try c.encodeIfPresent(d, forKey: .durationMs)
        case .chat(let text, let movieMs):
            try c.encode(text, forKey: .text)
            // nullable per protocol: send explicit null rather than omitting.
            if let movieMs { try c.encode(movieMs, forKey: .movieMs) } else { try c.encodeNil(forKey: .movieMs) }
        case .generalChat(let text):
            try c.encode(text, forKey: .text)
        case .chatPage(let movieId, let before):
            try c.encode(movieId, forKey: .movieId)
            try c.encodeIfPresent(before, forKey: .before)
        case .setAutoWait(let enabled):
            try c.encode(enabled, forKey: .enabled)
        }
    }

    public func jsonString() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
