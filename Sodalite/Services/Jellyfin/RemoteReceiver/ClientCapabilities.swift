import Foundation

/// The body of `POST /Sessions/Capabilities/Full`: what other clients may ask of this device.
///
/// `SupportedCommands` lists only the general commands the receiver acts on. Playstate commands
/// (pause, seek, stop) need no entry: `SupportsMediaControl` together with an open socket is what
/// makes the server offer them.
nonisolated struct ClientCapabilities: Encodable, Sendable, Equatable {
    let playableMediaTypes: [String]
    let supportedCommands: [String]
    let supportsMediaControl: Bool
    let supportsPersistentIdentifier: Bool

    static let receiver = ClientCapabilities(
        playableMediaTypes: ["Video"],
        supportedCommands: ["Play", "PlayState", "DisplayContent"],
        supportsMediaControl: true,
        supportsPersistentIdentifier: true
    )

    private enum CodingKeys: String, CodingKey {
        case playableMediaTypes = "PlayableMediaTypes"
        case supportedCommands = "SupportedCommands"
        case supportsMediaControl = "SupportsMediaControl"
        case supportsPersistentIdentifier = "SupportsPersistentIdentifier"
    }
}
