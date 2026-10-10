import Foundation

/// One message off Jellyfin's `/socket`, decoded at the boundary so nothing past it reads JSON.
///
/// Only the messages this device acts on get a case. Everything else the server pushes (library
/// changes, user data, timers, other sessions) arrives as `.other` and is dropped by the receiver.
nonisolated enum JellyfinSocketMessage: Equatable, Sendable {
    /// The server's idle timeout in seconds. The client answers with `KeepAlive` at half of it.
    case forceKeepAlive(seconds: Int)
    case playstate(SocketPlaystateCommand)
    case play(SocketPlayRequest)
    case generalCommand(SocketGeneralCommand)
    case other(type: String)

    static func decode(_ data: Data) -> JellyfinSocketMessage? {
        guard let type = try? JSONDecoder().decode(MessageType.self, from: data).messageType else { return nil }
        switch type {
        case "ForceKeepAlive":
            let seconds = payload(Int.self, in: data) ?? payload(Double.self, in: data).map { Int($0) }
            return seconds.map { .forceKeepAlive(seconds: $0) }
        case "Playstate":
            return payload(PlaystateData.self, in: data)
                .flatMap(SocketPlaystateCommand.init(data:))
                .map(JellyfinSocketMessage.playstate)
        case "Play":
            return payload(PlayData.self, in: data)
                .flatMap(SocketPlayRequest.init(data:))
                .map(JellyfinSocketMessage.play)
        case "GeneralCommand":
            return payload(GeneralCommandData.self, in: data)
                .map { .generalCommand(SocketGeneralCommand(name: $0.name, arguments: $0.arguments ?? [:])) }
        default:
            return .other(type: type)
        }
    }

    /// What the client sends back to keep the server from closing an idle socket.
    static let keepAliveFrame = #"{"MessageType":"KeepAlive"}"#

    private struct MessageType: Decodable {
        let messageType: String

        private enum CodingKeys: String, CodingKey {
            case messageType = "MessageType"
        }
    }

    /// `Data` changes shape with the message type, so it is decoded a second time once the type
    /// is known.
    private struct Payload<T: Decodable>: Decodable {
        let data: T

        private enum CodingKeys: String, CodingKey {
            case data = "Data"
        }
    }

    private static func payload<T: Decodable>(_ type: T.Type, in data: Data) -> T? {
        try? JSONDecoder().decode(Payload<T>.self, from: data).data
    }

    fileprivate struct PlaystateData: Decodable {
        let command: String
        let seekPositionTicks: Int64?

        private enum CodingKeys: String, CodingKey {
            case command = "Command"
            case seekPositionTicks = "SeekPositionTicks"
        }
    }

    fileprivate struct PlayData: Decodable {
        let itemIDs: [String]
        let startPositionTicks: Int64?
        let playCommand: String

        private enum CodingKeys: String, CodingKey {
            case itemIDs = "ItemIds"
            case startPositionTicks = "StartPositionTicks"
            case playCommand = "PlayCommand"
        }
    }

    fileprivate struct GeneralCommandData: Decodable {
        let name: String
        let arguments: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case arguments = "Arguments"
        }
    }
}

/// A `Playstate` command from another client. Seek carries seconds, converted from ticks here.
nonisolated enum SocketPlaystateCommand: Equatable, Sendable {
    case pause
    case unpause
    case playPause
    case stop
    case seek(seconds: Double)
    case nextTrack
    case previousTrack

    fileprivate init?(data: JellyfinSocketMessage.PlaystateData) {
        switch data.command {
        case "Pause": self = .pause
        case "Unpause": self = .unpause
        case "PlayPause": self = .playPause
        case "Stop": self = .stop
        case "Seek":
            guard let ticks = data.seekPositionTicks else { return nil }
            self = .seek(seconds: Double(max(ticks, 0)) / Double(RemoteSession.ticksPerSecond))
        case "NextTrack": self = .nextTrack
        case "PreviousTrack": self = .previousTrack
        default: return nil
        }
    }
}

/// A `Play` request. Only `PlayNow` starts anything: this player has no queue to add to.
nonisolated struct SocketPlayRequest: Equatable, Sendable {
    let itemID: String
    let startPositionTicks: Int64?

    fileprivate init?(data: JellyfinSocketMessage.PlayData) {
        guard data.playCommand == "PlayNow", let first = data.itemIDs.first else { return nil }
        itemID = first
        startPositionTicks = data.startPositionTicks
    }

    init(itemID: String, startPositionTicks: Int64?) {
        self.itemID = itemID
        self.startPositionTicks = startPositionTicks
    }
}

nonisolated struct SocketGeneralCommand: Equatable, Sendable {
    let name: String
    let arguments: [String: String]
}
