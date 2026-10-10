import Foundation

/// What the local player looks like right now, as far as the sync layer cares.
public struct LocalPlayerState: Sendable, Equatable {
    public var loadedMovieId: String?
    /// Media opened and producing time updates (not opening / stalled).
    public var isReady: Bool
    /// The play/pause intent last applied to the player.
    public var isPlaying: Bool
    /// Best estimate of the current position (interpolated), nil until known.
    public var positionMs: Int64?
    /// A seek was issued and the player hasn't reported progress from the new position yet.
    public var isSeeking: Bool

    public init(loadedMovieId: String?, isReady: Bool, isPlaying: Bool, positionMs: Int64?, isSeeking: Bool = false) {
        self.loadedMovieId = loadedMovieId
        self.isReady = isReady
        self.isPlaying = isPlaying
        self.positionMs = positionMs
        self.isSeeking = isSeeking
    }

    public static let empty = LocalPlayerState(loadedMovieId: nil, isReady: false, isPlaying: false, positionMs: nil)
}

/// Reduces (room state, local player state, clock) → player commands.
/// Pure and deterministic; the app calls it on every `room` message and on a 250 ms tick.
public struct SyncEngine: Sendable {
    public private(set) var drift: DriftController
    private var lastAction: LastAction?
    private var hasSeenRoom = false

    public init(config: DriftConfig = DriftConfig()) {
        drift = DriftController(config: config)
    }

    /// The most recent seek we issued was a drift correction (not an explicit user seek).
    private var lastSeekWasDrift = false

    /// Measured by the player: time from issuing a playing seek until playback resumed.
    /// Only drift-correction seeks train the lead: they are short hops within the same stretch
    /// of file, while user seeks jump anywhere and are resolved together via auto-wait.
    public mutating func recordSeekLatency(_ ms: Int64) {
        guard lastSeekWasDrift else { return }
        drift.recordSeekLatency(ms)
    }

    public mutating func reset() {
        drift.reset()
        lastAction = nil
        hasSeenRoom = false
    }

    public mutating func reconcile(room: RoomState?, joined: Bool, local: LocalPlayerState,
                                   serverNow: Int64, now: Int64) -> [PlayerCommand] {
        guard joined, let room else {
            reset()
            return local.loadedMovieId == nil ? [] : [.unload]
        }

        let target = room.effectivePosition(serverNow: serverNow)
        // A new user action (not merely a new rev: status changes bump rev too).
        let isNewAction = hasSeenRoom && room.lastAction != nil && room.lastAction != lastAction
        lastAction = room.lastAction
        hasSeenRoom = true

        if local.loadedMovieId != room.movie.id {
            drift.reset()
            return [.load(movie: room.movie, startMs: target, play: room.playing)]
        }

        var out: [PlayerCommand] = []
        if room.playing != local.isPlaying {
            out.append(room.playing ? .play : .pause)
        }

        guard let actual = local.positionMs else { return out }

        // An explicit seek by anyone: honour it precisely even if it is within the rate band,
        // and even while this player is stalled or stuck (seeking away is how users recover).
        if isNewAction, room.lastAction?.action == "seek",
           abs(target - actual) > drift.config.pausedSeekThresholdMs {
            // Explicit seeks go exactly where asked; everyone repositions together.
            if drift.isCorrecting { out.append(.setRate(1.0)) }
            drift.noteSeek(now: now)
            lastSeekWasDrift = false
            out.append(.seek(target))
            return out
        }

        // The server's EOF pause anchors at duration. Do not drift-seek back into the
        // terminal input just to match that anchor; an explicit backward seek above
        // still recovers normally and preserves the room's paused intent.
        if !room.playing, room.lastAction?.action == "ended" {
            if drift.isCorrecting { out.append(.setRate(1.0)); drift.reset() }
            return out
        }

        guard local.isReady else { return out }

        // At the end of the movie (the server keeps the clock running past durationMs): let the
        // player run out on its own instead of seeking back to the last second repeatedly.
        if room.playing, let d = room.durationMs, d > 0, target >= d - 1500 {
            if drift.isCorrecting { out.append(.setRate(1.0)); drift.reset() }
            return out
        }

        // Mid-seek while playing: VLC's clock is meaningless until it reports progress again.
        if room.playing && local.isSeeking { return out }

        let autoPaused = !room.playing && room.lastAction?.action == "autoWait"
        let corrections = drift.evaluate(target: target, actual: actual, playing: room.playing, now: now,
                                         relaxedPause: autoPaused)
        if corrections.contains(where: { if case .seek = $0 { true } else { false } }) {
            lastSeekWasDrift = room.playing
        }
        out.append(contentsOf: corrections)
        return out
    }
}

/// Decides whether we report `ready` or `buffering` in `status`.
public enum PlaybackHealth {
    /// - Parameters:
    ///   - opened: the media has produced at least one time update since load / seek.
    ///   - wantsPlaying: the room is playing and we applied that intent.
    ///   - msSinceTimeAdvanced: how long since the player's time last moved (nil if never).
    ///   - terminal: playback ended, failed, or was given up on. Report `ready` so the room's
    ///     auto-wait never holds everyone hostage to a file this client can't play.
    ///   - seeking: a seek hasn't produced output at the new position yet. Reported as buffering
    ///     so the room doesn't resume (autoResume) into a player that is still repositioning.
    public static func state(opened: Bool, wantsPlaying: Bool, msSinceTimeAdvanced: Int64?,
                             seeking: Bool = false, terminal: Bool = false,
                             stallThresholdMs: Int64 = 1000) -> ParticipantState {
        if terminal { return .ready }
        if !opened || seeking { return .buffering }
        if wantsPlaying, let since = msSinceTimeAdvanced, since > stallThresholdMs { return .buffering }
        return .ready
    }
}

/// VLC reports time in coarse steps; interpolate between updates so drift math is smooth.
public struct PositionInterpolator: Sendable {
    public private(set) var anchorMs: Int64?
    public private(set) var anchorAt: Int64 = 0
    public private(set) var lastAdvanceAt: Int64?
    /// Never extrapolate further than this past the last real update (protects against stalls).
    public var maxExtrapolationMs: Int64 = 1000

    public init() {}

    public mutating func reset() {
        anchorMs = nil
        lastAdvanceAt = nil
    }

    /// Feed the raw player time. Returns true if it moved.
    @discardableResult
    public mutating func observe(rawMs: Int64, now: Int64) -> Bool {
        if rawMs != anchorMs {
            anchorMs = rawMs
            anchorAt = now
            lastAdvanceAt = now
            return true
        }
        return false
    }

    /// Restart the stall clock: call when playback is (re)started so time spent paused or
    /// before a seek doesn't count as a stall.
    public mutating func expectProgress(now: Int64) {
        lastAdvanceAt = now
    }

    /// Hard re-anchor (e.g. right after we issued a seek).
    public mutating func jump(to ms: Int64, now: Int64) {
        anchorMs = ms
        anchorAt = now
    }

    public func position(now: Int64, playing: Bool, rate: Float) -> Int64? {
        guard let anchorMs else { return nil }
        guard playing else { return anchorMs }
        let elapsed = min(max(0, now - anchorAt), maxExtrapolationMs)
        return anchorMs + Int64((Double(elapsed) * Double(rate)).rounded())
    }

    public func msSinceAdvance(now: Int64) -> Int64? {
        lastAdvanceAt.map { now - $0 }
    }
}
