import Foundation

/// What `awake skill` says about one agent: pure words, so the CLI prints them and a
/// scene shows the same sentence. Paths are given as a person reads them (`~/…`).
public enum SkillWords {
    public enum State: Sendable {
        case installed(String)
        case notOnMac
        case ownFolder(String)
        case linkedElsewhere(String)
        case notInstalled
        case removed(String)
        case skipped
    }

    public static func line(_ agent: String, _ state: State) -> String {
        switch state {
        case .installed(let path): "\(agent): installed at \(path)"
        case .notOnMac: "\(agent): not on this Mac"
        case .ownFolder(let path): "\(agent): \(path) is a folder of your own, left as it is"
        case .linkedElsewhere(let to): "\(agent): linked to \(to)"
        case .notInstalled: "\(agent): not installed (awake skill install)"
        case .removed(let path): "\(agent): removed \(path)"
        case .skipped: "\(agent): not on this Mac, skipped"
        }
    }
}
