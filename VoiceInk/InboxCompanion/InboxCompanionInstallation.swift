import Foundation

enum InboxCompanionInstallation {
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInk", isDirectory: true)
            .appendingPathComponent("InboxCompanion", isDirectory: true)
            .standardizedFileURL
    }

    static func promptURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("inbox-transcription-prompt.txt")
    }
}
