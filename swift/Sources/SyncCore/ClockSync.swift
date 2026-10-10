import Foundation

/// Estimates the offset between the local clock and the server clock.
///
/// PROTOCOL client rule: offset = serverTime - (t0 + rtt/2), taken from the lowest-RTT sample
/// of the last 10. `serverNow = localNow + offset`.
public struct ClockOffsetEstimator: Sendable {
    public struct Sample: Sendable, Equatable {
        public var t0: Int64          // local send time
        public var t1: Int64          // local receive time
        public var serverTime: Int64

        public var rtt: Int64 { max(0, t1 - t0) }
        public var offset: Int64 { serverTime - (t0 + rtt / 2) }
    }

    public let capacity: Int
    public private(set) var samples: [Sample] = []

    public init(capacity: Int = 10) {
        self.capacity = capacity
    }

    /// Records a pong. `t0` is the `clientTime` echoed by the server, `t1` the local receive time.
    public mutating func add(t0: Int64, serverTime: Int64, t1: Int64) {
        guard t1 >= t0 else { return } // clock went backwards or bogus echo
        samples.append(Sample(t0: t0, t1: t1, serverTime: serverTime))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var best: Sample? { samples.min { $0.rtt < $1.rtt } }
    public var offset: Int64? { best?.offset }
    public var bestRtt: Int64? { best?.rtt }
    public var hasEstimate: Bool { !samples.isEmpty }

    public func serverNow(localNow: Int64) -> Int64 {
        localNow + (offset ?? 0)
    }

    public mutating func reset() { samples.removeAll() }
}

public enum LocalClock {
    /// Wall-clock milliseconds. The offset estimator absorbs any skew versus the server.
    public static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
