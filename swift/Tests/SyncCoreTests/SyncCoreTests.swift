import Foundation
import Testing
@testable import SyncCore

// MARK: - Clock offset

@Suite("Clock offset estimator")
struct ClockOffsetTests {
    @Test func offsetFromSingleSample() {
        var c = ClockOffsetEstimator()
        // Sent at 1000, received at 1100 (rtt 100). Server stamped 5050 → offset = 5050 - (1000 + 50) = 4000.
        c.add(t0: 1000, serverTime: 5050, t1: 1100)
        #expect(c.offset == 4000)
        #expect(c.bestRtt == 100)
        #expect(c.serverNow(localNow: 2000) == 6000)
    }

    @Test func usesMinimumRttSample() {
        var c = ClockOffsetEstimator()
        c.add(t0: 0, serverTime: 10_300, t1: 400)     // rtt 400, offset 10_100 (asymmetric, noisy)
        c.add(t0: 1000, serverTime: 11_010, t1: 1020) // rtt 20, offset 10_000  ← best
        c.add(t0: 2000, serverTime: 12_150, t1: 2200) // rtt 200, offset 10_050
        #expect(c.bestRtt == 20)
        #expect(c.offset == 10_000)
    }

    @Test func keepsOnlyLastTenSamples() {
        var c = ClockOffsetEstimator()
        c.add(t0: 0, serverTime: 505, t1: 10)             // rtt 10, offset 500 — will be evicted
        for i in 1...10 {
            let t0 = Int64(i * 1000)
            c.add(t0: t0, serverTime: t0 + 50 + 700, t1: t0 + 100) // rtt 100, offset 700
        }
        #expect(c.samples.count == 10)
        #expect(c.offset == 700)
    }

    @Test func ignoresBackwardsSamplesAndDefaultsToZero() {
        var c = ClockOffsetEstimator()
        #expect(c.offset == nil)
        #expect(c.serverNow(localNow: 123) == 123)
        c.add(t0: 500, serverTime: 1, t1: 400)
        #expect(!c.hasEstimate)
    }
}

// MARK: - Effective position

@Suite("Effective position")
struct EffectivePositionTests {
    @Test func playingAdvancesWithServerTime() {
        let r = Fixtures.room(playing: true, positionMs: 734_000, asOf: 1_758_830_000_000)
        #expect(r.effectivePosition(serverNow: 1_758_830_000_000) == 734_000)
        #expect(r.effectivePosition(serverNow: 1_758_830_002_500) == 736_500)
    }

    @Test func pausedIsFrozen() {
        let r = Fixtures.room(playing: false, positionMs: 734_000, asOf: 1_758_830_000_000)
        #expect(r.effectivePosition(serverNow: 1_758_830_060_000) == 734_000)
    }

    @Test func clampsToDurationAndZero() {
        var r = Fixtures.room(playing: true, positionMs: 7_019_000, asOf: 0, durationMs: 7_020_000)
        #expect(r.effectivePosition(serverNow: 10_000) == 7_020_000)
        r.positionMs = 0
        #expect(r.effectivePosition(serverNow: -5_000) == 0)
    }
}

// MARK: - Drift thresholds

@Suite("Drift controller")
struct DriftTests {
    let now: Int64 = 1_000_000

    @Test func playingSeeksAboveOneSecond() {
        var d = DriftController()
        #expect(d.evaluate(target: 10_000, actual: 8_900, playing: true, now: now) == [.seek(10_000)])
        var d2 = DriftController()
        #expect(d2.evaluate(target: 10_000, actual: 11_001, playing: true, now: now) == [.seek(10_000)])
    }

    @Test func playingExactlyOneSecondUsesRateNotSeek() {
        var d = DriftController()
        #expect(d.evaluate(target: 10_000, actual: 9_000, playing: true, now: now) == [.setRate(1.05)])
    }

    @Test func behindSpeedsUpAheadSlowsDown() {
        var behind = DriftController()
        #expect(behind.evaluate(target: 10_000, actual: 9_500, playing: true, now: now) == [.setRate(1.05)])
        var ahead = DriftController()
        #expect(ahead.evaluate(target: 10_000, actual: 10_500, playing: true, now: now) == [.setRate(0.95)])
    }

    @Test func withinHundredMsDoesNothingWhenNotCorrecting() {
        var d = DriftController()
        #expect(d.evaluate(target: 10_000, actual: 9_900, playing: true, now: now).isEmpty)
        #expect(d.evaluate(target: 10_000, actual: 10_100, playing: true, now: now).isEmpty)
        #expect(d.currentRate == 1.0)
    }

    @Test func keepsCorrectingUntilWithin40msThenBackToNormal() {
        var d = DriftController()
        #expect(d.evaluate(target: 10_000, actual: 9_700, playing: true, now: now) == [.setRate(1.05)])
        // Still 300 → no new command, keeps 1.05.
        #expect(d.evaluate(target: 10_000, actual: 9_700, playing: true, now: now + 200).isEmpty)
        // 80 ms: inside the 100 ms band but not settled yet → keep correcting.
        #expect(d.evaluate(target: 10_000, actual: 9_920, playing: true, now: now + 400).isEmpty)
        #expect(d.currentRate == 1.05)
        // 41 ms → still correcting.
        #expect(d.evaluate(target: 10_000, actual: 9_959, playing: true, now: now + 600).isEmpty)
        // 40 ms → settle.
        #expect(d.evaluate(target: 10_000, actual: 9_960, playing: true, now: now + 800) == [.setRate(1.0)])
        #expect(d.currentRate == 1.0)
    }

    @Test func overshootReturnsToNormalRate() {
        var d = DriftController()
        _ = d.evaluate(target: 10_000, actual: 9_500, playing: true, now: now) // 1.05
        // Now 60 ms ahead while speeding up → stop.
        #expect(d.evaluate(target: 10_000, actual: 10_060, playing: true, now: now + 100) == [.setRate(1.0)])
    }

    @Test func directionFlipSwitchesRate() {
        var d = DriftController()
        _ = d.evaluate(target: 10_000, actual: 9_500, playing: true, now: now)
        #expect(d.evaluate(target: 10_000, actual: 10_300, playing: true, now: now + 100) == [.setRate(0.95)])
    }

    @Test func pausedSeeksAbove250ms() {
        var d = DriftController()
        #expect(d.evaluate(target: 10_000, actual: 9_749, playing: false, now: now) == [.seek(10_000)])
        var d2 = DriftController()
        #expect(d2.evaluate(target: 10_000, actual: 9_750, playing: false, now: now).isEmpty)
        #expect(d2.evaluate(target: 10_000, actual: 10_200, playing: false, now: now).isEmpty)
    }

    @Test func pausedResetsRate() {
        var d = DriftController()
        _ = d.evaluate(target: 10_000, actual: 9_500, playing: true, now: now)
        #expect(d.evaluate(target: 10_000, actual: 10_000, playing: false, now: now + 100) == [.setRate(1.0)])
    }

    @Test func seekCooldownSuppressesFurtherCorrection() {
        var d = DriftController()
        #expect(d.evaluate(target: 20_000, actual: 5_000, playing: true, now: now) == [.seek(20_000)])
        // Player hasn't caught up yet; still within cooldown → nothing.
        #expect(d.evaluate(target: 20_500, actual: 5_000, playing: true, now: now + 500).isEmpty)
        // After cooldown, evaluate normally.
        #expect(d.evaluate(target: 21_600, actual: 21_300, playing: true, now: now + 1_600) == [.setRate(1.05)])
    }

    @Test func seekLeadCompensatesMeasuredLatencyOnlyWhilePlaying() {
        var d = DriftController()
        #expect(d.evaluate(target: 20_000, actual: 5_000, playing: true, now: now) == [.seek(20_000)])
        d.recordSeekLatency(2_000)
        #expect(d.seekLeadMs == 2_000)
        d.recordSeekLatency(1_000)
        #expect(d.seekLeadMs == 1_500)
        d.recordSeekLatency(60_000)
        #expect(d.seekLeadMs == 2_750) // sample clamped to 4000 before smoothing
        #expect(d.evaluate(target: 30_000, actual: 28_000, playing: true, now: now + 2_000) == [.seek(32_750)])
        #expect(d.seekTarget(for: 30_000, playing: false) == 30_000)
    }
}

// MARK: - Sync engine (room state → player commands)

@Suite("Sync engine")
struct SyncEngineTests {
    let now: Int64 = 5_000_000

    @Test func notJoinedUnloads() {
        var e = SyncEngine()
        let local = LocalPlayerState(loadedMovieId: "abc", isReady: true, isPlaying: true, positionMs: 1)
        #expect(e.reconcile(room: Fixtures.room(), joined: false, local: local, serverNow: 0, now: now) == [.unload])
        #expect(e.reconcile(room: nil, joined: true, local: .empty, serverNow: 0, now: now).isEmpty)
    }

    @Test func loadsMovieAtEffectivePosition() {
        var e = SyncEngine()
        let r = Fixtures.room(playing: true, positionMs: 60_000, asOf: 1_000)
        let cmds = e.reconcile(room: r, joined: true, local: .empty, serverNow: 4_000, now: now)
        #expect(cmds == [.load(movie: r.movie, startMs: 63_000, play: true)])
    }

    @Test func eofPauseDoesNotSeekIntoTerminalInputButBackwardSeekStillWorks() {
        var e = SyncEngine()
        var r = Fixtures.room(playing: true, positionMs: 11900, asOf: 1000)
        r.durationMs = 12000
        // A terminal player's health may still be ready, so this must skip drift
        // correction independently of the not-ready guard.
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 11300)
        _ = e.reconcile(room: r, joined: true, local: local, serverNow: 1000, now: now)
        r.playing = false
        r.positionMs = 12000
        r.lastAction = LastAction(by: "", action: "ended", at: 2000)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 2000, now: now + 100) == [.pause])
        let paused = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: false, positionMs: 11300)
        #expect(e.reconcile(room: r, joined: true, local: paused, serverNow: 2100, now: now + 200).isEmpty)
        r.positionMs = 4000
        r.lastAction = LastAction(by: "test", action: "seek", at: 2200)
        let terminal = LocalPlayerState(loadedMovieId: r.movie.id, isReady: false, isPlaying: false, positionMs: 11300)
        #expect(e.reconcile(room: r, joined: true, local: terminal, serverNow: 2200, now: now + 300) == [.seek(4000)])
    }

    @Test func followsPlayPauseIntent() {
        var e = SyncEngine()
        let r = Fixtures.room(playing: false, positionMs: 60_000, asOf: 1_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 60_100)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 2_000, now: now) == [.pause])
    }

    @Test func explicitSeekHonouredEvenInsideRateBand() {
        var e = SyncEngine()
        var r = Fixtures.room(playing: true, positionMs: 60_000, asOf: 1_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 60_000)
        _ = e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now)
        r.rev += 1
        r.positionMs = 60_600
        r.lastAction = LastAction(by: "Casey", action: "seek", at: 1_000)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now + 100) == [.seek(60_600)])
    }

    @Test func revBumpWithoutNewActionDoesNotReseek() {
        var e = SyncEngine()
        var r = Fixtures.room(playing: true, positionMs: 60_000, asOf: 1_000)
        r.lastAction = LastAction(by: "Casey", action: "seek", at: 1_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 60_000)
        _ = e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now)
        // Someone's status flipped: rev bumps, lastAction unchanged, we're 400 ms behind → rate, not seek.
        r.rev += 1
        let behind = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 60_600)
        #expect(e.reconcile(room: r, joined: true, local: behind, serverNow: 2_000, now: now + 5_000) == [.setRate(1.05)])
    }

    @Test func seekingWhilePlayingSkipsDrift() {
        var e = SyncEngine()
        let r = Fixtures.room(playing: true, positionMs: 60_000, asOf: 1_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 50_000, isSeeking: true)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now).isEmpty)
    }

    @Test func autoWaitPauseLeavesSmallOffsetsForRateCorrection() {
        var e = SyncEngine()
        var r = Fixtures.room(playing: false, positionMs: 60_000, asOf: 1_000)
        r.lastAction = LastAction(by: "Casey", action: "autoWait", at: 1_000)
        let behind = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: false, positionMs: 59_400)
        #expect(e.reconcile(room: r, joined: true, local: behind, serverNow: 1_000, now: now).isEmpty)
        let farBehind = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: false, positionMs: 58_000)
        #expect(e.reconcile(room: r, joined: true, local: farBehind, serverNow: 1_000, now: now + 100) == [.seek(60_000)])
        // A user pause uses the strict 250 ms rule.
        var e2 = SyncEngine()
        r.lastAction = LastAction(by: "Casey", action: "pause", at: 1_000)
        #expect(e2.reconcile(room: r, joined: true, local: behind, serverNow: 1_000, now: now) == [.seek(60_000)])
    }

    @Test func noCorrectionsAtTheEnd() {
        var e = SyncEngine()
        let r = Fixtures.room(playing: true, positionMs: 7_019_000, asOf: 0, durationMs: 7_020_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 7_022_000)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 60_000, now: now).isEmpty)
    }

    @Test func onlyDriftSeeksTrainTheLead() {
        var e = SyncEngine()
        var r = Fixtures.room(playing: true, positionMs: 60_000, asOf: 1_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 60_000)
        _ = e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now)
        r.rev += 1
        r.positionMs = 90_000
        r.lastAction = LastAction(by: "Casey", action: "seek", at: 2_000)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now + 100) == [.seek(90_000)])
        e.recordSeekLatency(1_500)
        #expect(e.drift.seekLeadMs == 0)
        // Later we drift 3 s behind → drift seek (no lead yet), and its latency does train.
        let behind = LocalPlayerState(loadedMovieId: r.movie.id, isReady: true, isPlaying: true, positionMs: 87_000)
        #expect(e.reconcile(room: r, joined: true, local: behind, serverNow: 1_000, now: now + 5_000) == [.seek(90_000)])
        e.recordSeekLatency(800)
        #expect(e.drift.seekLeadMs == 800)
    }

    @Test func notReadySkipsDrift() {
        var e = SyncEngine()
        let r = Fixtures.room(playing: true, positionMs: 60_000, asOf: 1_000)
        let local = LocalPlayerState(loadedMovieId: r.movie.id, isReady: false, isPlaying: true, positionMs: 10)
        #expect(e.reconcile(room: r, joined: true, local: local, serverNow: 1_000, now: now).isEmpty)
    }
}

// MARK: - Helpers

@Suite("Formatting, toasts, playback health")
struct MiscTests {
    @Test func hms() {
        #expect(TimeFormat.hms(0) == "0:00:00")
        #expect(TimeFormat.hms(65_000) == "0:01:05")
        #expect(TimeFormat.hms(3_730_999) == "1:02:10")
        #expect(TimeFormat.compact(245_000) == "4:05")
    }

    @Test func toastsOnlyForOthersAndNewActions() {
        var r = Fixtures.room()
        r.positionMs = 3_730_000
        r.lastAction = LastAction(by: "Casey", action: "seek", at: 1)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Alex") == "Casey seeked to 1:02:10")
        #expect(ActionToast.toast(for: r, previous: r.lastAction, myName: "Alex") == nil)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Casey") == nil)
        r.lastAction = LastAction(by: "Sam", action: "pause", at: 2)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Alex") == "Sam paused")
        r.waiting = ["Casey"]
        r.lastAction = LastAction(by: "Casey", action: "autoWait", at: 3)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Casey") == "Waiting for Casey")
        r.waiting = []
        r.lastAction = LastAction(by: "Casey", action: "autoResume", at: 4)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Alex") == "Everyone's ready")
        r.lastAction = LastAction(by: "Alex", action: "start", at: 5)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Sam") == "Alex started 300 (2006)")
        r.lastAction = LastAction(by: "Alex", action: "pause", at: 6, connId: "c2")
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Alex", myConnId: "c2") == nil)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Alex", myConnId: "c3") == "Alex paused")
        r.lastAction = LastAction(by: "", action: "ended", at: 7)
        #expect(ActionToast.toast(for: r, previous: nil, myName: "Alex", myConnId: "c2") == "That's the end of 300 (2006)")
    }

    @Test func health() {
        #expect(PlaybackHealth.state(opened: false, wantsPlaying: false, msSinceTimeAdvanced: nil) == .buffering)
        #expect(PlaybackHealth.state(opened: true, wantsPlaying: true, msSinceTimeAdvanced: 200) == .ready)
        #expect(PlaybackHealth.state(opened: true, wantsPlaying: true, msSinceTimeAdvanced: 1_500) == .buffering)
        #expect(PlaybackHealth.state(opened: true, wantsPlaying: false, msSinceTimeAdvanced: 60_000) == .ready)
        #expect(PlaybackHealth.state(opened: false, wantsPlaying: true, msSinceTimeAdvanced: nil, terminal: true) == .ready)
        #expect(PlaybackHealth.state(opened: true, wantsPlaying: false, msSinceTimeAdvanced: 0, seeking: true) == .buffering)
        #expect(PlaybackHealth.state(opened: true, wantsPlaying: true, msSinceTimeAdvanced: 30_000, terminal: true) == .ready)
    }

    @Test func interpolator() {
        var p = PositionInterpolator()
        #expect(p.position(now: 0, playing: true, rate: 1) == nil)
        p.observe(rawMs: 10_000, now: 1_000)
        #expect(p.position(now: 1_250, playing: true, rate: 1) == 10_250)
        #expect(p.position(now: 1_200, playing: true, rate: 1.05) == 10_210)
        #expect(p.position(now: 9_000, playing: true, rate: 1) == 11_000) // capped extrapolation
        #expect(p.position(now: 9_000, playing: false, rate: 1) == 10_000)
        #expect(p.msSinceAdvance(now: 61_000) == 60_000)
        p.expectProgress(now: 61_000)
        #expect(p.msSinceAdvance(now: 61_300) == 300)
    }
}

enum Fixtures {
    static let movie = Movie(id: "a1b2c3d4e5f6", title: "Sample Film", year: 2006, quality: "2160p",
                             container: "mkv", sizeBytes: 6_260_778_527, addedAt: 1_717_520_000_000)

    static func room(playing: Bool = true, positionMs: Int64 = 0, asOf: Int64 = 0, durationMs: Int64? = nil) -> RoomState {
        RoomState(rev: 1, movie: movie, playing: playing, positionMs: positionMs, asOfServerTime: asOf,
                  durationMs: durationMs, autoWait: true, waiting: [], lastAction: nil,
                  participants: [], startedBy: "Alex", startedAt: 0)
    }
}
