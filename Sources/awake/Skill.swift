import AwakeKit
import AwakeSurface
import Foundation

/// `awake skill`: the agent skill that ships inside the app (`Contents/Resources/skill`),
/// linked into every coding agent on this Mac that reads skills: Claude Code
/// (`~/.claude/skills`) and Codex (`$CODEX_HOME/skills`, `~/.codex` by default). A link,
/// not a copy, so upgrading the app upgrades the skill in every agent at once. Only an
/// earlier link is ever replaced: a real folder at that path is the person's own, and
/// is refused, never overwritten. When the app is deleted, the daemon's self-uninstall
/// takes the links with it (`unlink(into:)`), so none is left dangling.
enum Skill {
    struct Home {
        let agent: String
        let root: URL
        var link: URL { root.appendingPathComponent("skills/awake") }
    }

    static var homes: [Home] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex =
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return [
            Home(agent: "Claude Code", root: home.appendingPathComponent(".claude")),
            Home(agent: "Codex", root: codex),
        ]
    }

    /// The skill inside the running bundle; nil for a bare development binary.
    static var bundled: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("skill"),
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path)
        else { return nil }
        return dir
    }

    static func run(_ args: [String]) {
        switch args.first {
        case nil: status()
        case "install": install()
        case "remove": remove()
        default: Client.die("usage: awake skill [install|remove]")
        }
    }

    private static func target(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    private static func agentPresent(_ h: Home) -> Bool {
        FileManager.default.fileExists(atPath: h.root.path)
    }

    static func status() {
        for h in homes {
            let state: String
            if !agentPresent(h) {
                state = "not on this Mac"
            } else if let to = target(h.link) {
                state = to == bundled?.path ? "installed" : "linked to \(to)"
            } else if FileManager.default.fileExists(atPath: h.link.path) {
                state = "a folder of your own at \(h.link.path)"
            } else {
                state = "not installed (awake skill install)"
            }
            print("\(h.agent): \(state)")
        }
    }

    static func install() {
        guard let skill = bundled else {
            Client.die("no bundled skill here: run the awake inside the installed app")
        }
        let fm = FileManager.default
        var linked = 0
        for h in homes {
            guard agentPresent(h) else {
                print("\(h.agent): not on this Mac, skipped")
                continue
            }
            if target(h.link) != nil {
                try? fm.removeItem(at: h.link)
            } else if fm.fileExists(atPath: h.link.path) {
                print("\(h.agent): \(h.link.path) is a folder of your own, left as it is")
                continue
            }
            do {
                try fm.createDirectory(
                    at: h.link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: h.link, withDestinationURL: skill)
                print("\(h.agent): installed at \(h.link.path)")
                linked += 1
            } catch {
                Client.die(
                    "\(h.agent): could not link \(h.link.path): \(error.localizedDescription)")
            }
        }
        if linked == 0 { Client.die("no agent took the skill: nothing linked") }
    }

    static func remove() {
        for h in homes {
            guard target(h.link) != nil else { continue }
            try? FileManager.default.removeItem(at: h.link)
            print("\(h.agent): removed \(h.link.path)")
        }
    }

    /// The links that point into `bundle`, removed: the app they lead to is gone.
    static func unlink(into bundle: String) {
        for h in homes {
            guard let to = target(h.link), to.hasPrefix(bundle + "/") else { continue }
            try? FileManager.default.removeItem(at: h.link)
            log("removed the \(h.agent) skill link into the deleted app")
        }
    }
}
