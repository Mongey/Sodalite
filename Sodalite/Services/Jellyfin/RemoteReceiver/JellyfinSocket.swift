import Foundation
import os.log

/// Who the socket connects as. A change in any field is a different connection, which is why the
/// app keys the socket's task on it.
nonisolated struct JellyfinSocketTarget: Equatable, Sendable {
    let baseURL: URL
    let authorization: String
    let deviceID: String

    /// `ws`/`wss` beside the server's own `http`/`https`, keeping any path prefix a reverse proxy
    /// serves Jellyfin under.
    var socketURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/socket"
        components.queryItems = [URLQueryItem(name: "deviceId", value: deviceID)]
        return components.url
    }
}

/// Holds Jellyfin's WebSocket open for this device so other clients can steer it.
///
/// `run` lives as long as the task that calls it: it connects, posts the capabilities once the
/// server has spoken, answers keep-alives, hands every other message to `onMessage`, and reconnects
/// with backoff when the socket drops. Cancelling the task closes the socket.
@MainActor
final class JellyfinSocket {
    private let target: JellyfinSocketTarget
    private let session: URLSession
    private let postCapabilities: () async -> Void
    private let onMessage: (JellyfinSocketMessage) -> Void
    private var lifecycle = JellyfinSocketLifecycle()

    init(
        target: JellyfinSocketTarget,
        session: URLSession = .shared,
        postCapabilities: @escaping () async -> Void,
        onMessage: @escaping (JellyfinSocketMessage) -> Void
    ) {
        self.target = target
        self.session = session
        self.postCapabilities = postCapabilities
        self.onMessage = onMessage
    }

    func run() async {
        guard let url = target.socketURL else { return }
        while !Task.isCancelled {
            await connectOnce(url: url)
            guard !Task.isCancelled else { return }
            let delay = lifecycle.didDrop()
            Self.log.notice("socket dropped, retrying in \(delay.components.seconds, privacy: .public)s")
            try? await Task.sleep(for: delay)
            lifecycle.retry()
        }
    }

    private func connectOnce(url: URL) async {
        var request = URLRequest(url: url)
        // The header rather than `api_key` in the query: newer servers turn the legacy query token
        // off, and a URL carrying the token ends up in proxy logs.
        request.setValue(target.authorization, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        var keepAlive: Task<Void, Never>?
        defer {
            keepAlive?.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard let message = try? await task.receive() else { return }
                guard let decoded = Self.decode(message) else { continue }
                if lifecycle.phase != .connected {
                    lifecycle.didReceiveMessage()
                    Self.log.notice("socket connected")
                    await postCapabilities()
                }
                if case .forceKeepAlive(let seconds) = decoded {
                    keepAlive?.cancel()
                    keepAlive = Self.keepAlive(on: task, every: .seconds(max(seconds / 2, 5)))
                } else {
                    onMessage(decoded)
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) -> JellyfinSocketMessage? {
        switch message {
        case .string(let text): JellyfinSocketMessage.decode(Data(text.utf8))
        case .data(let data): JellyfinSocketMessage.decode(data)
        @unknown default: nil
        }
    }

    private static func keepAlive(on task: URLSessionWebSocketTask, every interval: Duration) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await task.send(.string(JellyfinSocketMessage.keepAliveFrame))
                try? await Task.sleep(for: interval)
            }
        }
    }

    private static let log = Logger(subsystem: "de.superuser404.Sodalite", category: "RemoteReceiver")
}
