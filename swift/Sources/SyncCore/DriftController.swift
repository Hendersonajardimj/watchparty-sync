import Foundation

/// Commands the sync layer asks the local player to perform. The UI never drives the player
/// directly; everything goes through the server and comes back as `room` state.
public enum PlayerCommand: Equatable, Sendable {
    case load(movie: Movie, startMs: Int64, play: Bool)
    case unload
    case play
    case pause
    case seek(Int64)
    case setRate(Float)
}

public struct DriftConfig: Sendable, Equatable {
    /// Playing: |diff| above this → hard seek.
    public var seekThresholdMs: Int64 = 1000
    /// Playing: |diff| above this (and ≤ seekThreshold) → rate correction.
    public var rateThresholdMs: Int64 = 100
    /// Playing: while correcting, return to 1.0 once |diff| is within this.
    public var settleMs: Int64 = 40
    /// Paused: |diff| above this → seek.
    public var pausedSeekThresholdMs: Int64 = 250
    public var fastRate: Float = 1.05
    public var slowRate: Float = 0.95
    /// After issuing a seek, ignore drift for this long while the player repositions.
    public var seekCooldownMs: Int64 = 1500
    /// Upper bound for the seek lead (compensates for this player's own seek latency while playing).
    public var maxSeekLeadMs: Int64 = 4000

    public init() {}
}

/// Drift correction per PROTOCOL client rules:
///   playing: diff = target - actual
///     |diff| > 1000 ms          → seek to target
///     100 < |diff| ≤ 1000 ms    → rate 1.05 (behind) / 0.95 (ahead) until within 40 ms, then 1.0
///   paused: |diff| > 250 ms     → seek
public struct DriftController: Sendable {
    public var config: DriftConfig
    /// The rate we last asked the player for.
    public private(set) var currentRate: Float = 1.0
    public private(set) var lastSeekAt: Int64?
    /// Added to seeks while playing: the room keeps moving while the player reopens at the new
    /// position, so aim where the room will be. Learned from measured seek latency.
    public private(set) var seekLeadMs: Int64 = 0

    public init(config: DriftConfig = DriftConfig()) {
        self.config = config
    }

    public var isCorrecting: Bool { currentRate != 1.0 }

    public mutating func reset() {
        currentRate = 1.0
        lastSeekAt = nil
    }

    /// Feed the measured time from issuing a playing seek until playback visibly resumed.
    /// Smoothed (EMA ½) and clamped to [0, maxSeekLeadMs].
    public mutating func recordSeekLatency(_ ms: Int64) {
        let sample = min(max(0, ms), config.maxSeekLeadMs)
        seekLeadMs = seekLeadMs == 0 ? sample : (seekLeadMs + sample) / 2
    }

    /// Where to seek so we land on `target` after our own seek latency.
    public func seekTarget(for target: Int64, playing: Bool) -> Int64 {
        playing ? target + seekLeadMs : target
    }

    public func inCooldown(now: Int64) -> Bool {
        guard let lastSeekAt else { return false }
        return now - lastSeekAt < config.seekCooldownMs
    }

    /// Records that a seek was issued outside of `evaluate` (e.g. an explicit user seek).
    public mutating func noteSeek(now: Int64) {
        lastSeekAt = now
        currentRate = 1.0
    }

    /// - Parameter relaxedPause: the room is paused by the server's auto-wait (not by a user).
    ///   Small offsets are then left for rate correction after the resume instead of a paused
    ///   seek: on slow-seeking files a seek per auto-wait pause re-triggers the stall that caused
    ///   the pause, and the room stutters pause→seek→resume→stall indefinitely.
    public mutating func evaluate(target: Int64, actual: Int64, playing: Bool, now: Int64,
                                  relaxedPause: Bool = false) -> [PlayerCommand] {
        var out: [PlayerCommand] = []
        if inCooldown(now: now) { return out }

        let diff = target - actual
        let ad = abs(diff)

        if !playing {
            if isCorrecting {
                currentRate = 1.0
                out.append(.setRate(1.0))
            }
            if ad > (relaxedPause ? config.seekThresholdMs : config.pausedSeekThresholdMs) {
                out.append(.seek(target))
                lastSeekAt = now
            }
            return out
        }

        if ad > config.seekThresholdMs {
            if isCorrecting {
                currentRate = 1.0
                out.append(.setRate(1.0))
            }
            out.append(.seek(seekTarget(for: target, playing: true)))
            lastSeekAt = now
            return out
        }

        if ad > config.rateThresholdMs {
            let desired: Float = diff > 0 ? config.fastRate : config.slowRate
            if currentRate != desired {
                currentRate = desired
                out.append(.setRate(desired))
            }
            return out
        }

        if isCorrecting {
            // Within the settle window, or we overshot (sign flipped) — back to normal speed.
            let overshot = (currentRate > 1.0 && diff < 0) || (currentRate < 1.0 && diff > 0)
            if ad <= config.settleMs || overshot {
                currentRate = 1.0
                out.append(.setRate(1.0))
            }
        }
        return out
    }
}
