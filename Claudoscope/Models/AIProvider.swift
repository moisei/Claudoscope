import Foundation

/// Represents the AI coding tool whose data Claudoscope reads.
enum AIProvider: String, CaseIterable, Sendable {
    case claudeCode
    case cursor

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }

    var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .cursor: return "Cursor"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode: return "apple.terminal.fill"
        case .cursor: return "cursorarrow"
        }
    }

    /// The base directory for this provider's data.
    var baseDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return home.appendingPathComponent(".claude")
        case .cursor: return home.appendingPathComponent(".cursor")
        }
    }

    /// The skills subdirectory name.
    var skillsDirName: String {
        switch self {
        case .claudeCode: return "skills"
        case .cursor: return "skills-cursor"
        }
    }

    /// Whether sessions are stored inside `agent-transcripts/<id>/<id>.jsonl` subdirectories.
    var usesAgentTranscripts: Bool {
        switch self {
        case .claudeCode: return false
        case .cursor: return true
        }
    }

    /// Key used for persisting the selected provider in UserDefaults.
    static let userDefaultsKey = "selectedAIProvider"
}
