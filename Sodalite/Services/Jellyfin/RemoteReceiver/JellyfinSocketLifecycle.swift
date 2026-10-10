import Foundation

/// Where one socket run stands, and how long to wait before the next attempt.
///
/// Stopping is not a state here: the run belongs to a SwiftUI `.task(id:)` keyed on who is signed
/// in, whether remote control is allowed and whether the app is in use, so sign-out, a profile or
/// server switch, the setting going off and the app leaving the foreground all cancel the task, and
/// a change back starts a fresh run at attempt zero.
nonisolated struct JellyfinSocketLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case connecting(attempt: Int)
        /// The server has spoken on the socket, so it holds this device as controllable.
        case connected
        case waiting(attempt: Int, delay: Duration)
    }

    private(set) var phase: Phase = .connecting(attempt: 0)

    /// The first message proves the socket is open. A drop after that starts the backoff over.
    mutating func didReceiveMessage() {
        phase = .connected
    }

    /// The socket closed or failed to open. Returns how long to wait before trying again.
    @discardableResult
    mutating func didDrop() -> Duration {
        let attempt: Int
        switch phase {
        case .connected: attempt = 0
        case .connecting(let current): attempt = current
        case .waiting(let current, _): attempt = current
        }
        let delay = Self.backoff(attempt: attempt)
        phase = .waiting(attempt: attempt + 1, delay: delay)
        return delay
    }

    mutating func retry() {
        guard case .waiting(let attempt, _) = phase else { return }
        phase = .connecting(attempt: attempt)
    }

    /// 1, 2, 4, 8, 16, 32 seconds, then a minute between tries for as long as the server stays away.
    static func backoff(attempt: Int) -> Duration {
        .seconds(min(1 << min(attempt, 6), 60))
    }
}
