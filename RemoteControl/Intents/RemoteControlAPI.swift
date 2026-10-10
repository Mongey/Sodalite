import CoreGraphics
import Foundation
import ImageIO

/// The remote-control client the widget, the Control Center control and the Shortcuts actions share:
/// list the sessions, send a command, fetch one poster. Not the app's client, for the reason
/// `TopShelfAPI` gives: an extension runs on a tight memory budget, and the app's dependency graph
/// is a lot to carry for three requests. An action Shortcuts runs in the app's process takes this
/// client too, so it works the same whether or not the app has signed in yet this launch.
nonisolated struct RemoteControlAPI: Sendable {
    let session: SharedSession

    /// Its own stable id in the app group, distinct from the app's and the Top Shelf's, so the
    /// widget's refreshes and the actions show up in Jellyfin's session list as one device rather
    /// than a new one per timeline.
    static let deviceID: String = {
        let defaults = UserDefaults(suiteName: RemoteControlAppGroup.id)
        let key = "remoteControl.deviceID"
        if let existing = defaults?.string(forKey: key) { return existing }
        let new = UUID().uuidString
        defaults?.set(new, forKey: key)
        return new
    }()

    func controllableSessions() async throws -> [RemoteSession] {
        let url = endpoint(path: RemoteSession.listPath, query: RemoteSession.listQuery(userID: session.userID))
        let data = try await send(URLRequest(url: url))
        let sessions = try JSONDecoder().decode([RemoteSession].self, from: data)
        return RemoteSession.controllable(sessions, excludingDeviceID: Self.deviceID)
    }

    func send(_ command: RemoteCommand, to sessionID: String) async throws {
        var request = URLRequest(url: endpoint(path: command.path(sessionID: sessionID), query: command.queryItems ?? []))
        request.httpMethod = "POST"
        _ = try await send(request)
    }

    /// The poster, downsampled to `maxPixelSize` before it is kept. A widget's memory limit is a
    /// few tens of megabytes, and a full-size poster decoded at its native size would spend most
    /// of it on one tile. ImageIO and CGImage rather than UIImage, so these sources carry over to
    /// a macOS widget unchanged.
    func poster(for playing: RemoteSession.NowPlaying, maxPixelSize: Int) async -> CGImage? {
        var query = [URLQueryItem(name: "maxHeight", value: String(maxPixelSize)), URLQueryItem(name: "quality", value: "85")]
        if let tag = playing.imageTag {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        let url = endpoint(path: "/Items/\(playing.imageItemID)/Images/Primary", query: query)
        guard let data = try? await send(URLRequest(url: url)),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func endpoint(path: String, query: [URLQueryItem]) -> URL {
        var base = session.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url!
    }

    /// Ephemeral and uncached, with a resource timeout: a widget has seconds to answer, and the
    /// state it shows has to be the server's current one.
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteControlHTTPError(status: http.statusCode)
        }
        return data
    }

    private var authHeader: String {
        let parts = [
            "Client=\"Sodalite\"",
            "Device=\"Sodalite Remote\"",
            "DeviceId=\"\(Self.deviceID)\"",
            "Version=\"1.0\"",
            "Token=\"\(session.accessToken)\"",
        ]
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
}

nonisolated struct RemoteControlHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? { "HTTP \(status)" }
}

nonisolated enum RemoteControlAppGroup {
    static let id = "group.de.superuser404.Sodalite"
}
