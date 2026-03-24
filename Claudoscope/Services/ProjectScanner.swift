import Foundation

/// Scans project directories to discover projects and session files.
/// Supports both Claude Code (~/.claude/) and Cursor (~/.cursor/) layouts.
struct ProjectScanner {
    let claudeDir: URL
    let parser: SessionParser
    let pricingTable: [String: ModelPricing]
    var provider: AIProvider = .claudeCode

    /// Scan all projects and collect session metadata
    func scan() async -> (projects: [Project], sessionsByProject: [String: [SessionSummary]]) {
        await parser.resetDedup()

        let projectsDir = claudeDir.appendingPathComponent("projects")
        var projects: [Project] = []
        var sessionsByProject: [String: [SessionSummary]] = [:]

        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: projectsDir.path) else {
            return (projects, sessionsByProject)
        }

        let projectDirs = dirNames.filter { name in
            var isDir: ObjCBool = false
            let fullPath = projectsDir.appendingPathComponent(name).path
            return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }

        await withTaskGroup(of: (String, [SessionSummary])?.self) { group in
            for dirName in projectDirs {
                let currentProvider = self.provider
                group.addTask {
                    let dirURL = projectsDir.appendingPathComponent(dirName)
                    guard let topFiles = try? fm.contentsOfDirectory(atPath: dirURL.path) else {
                        return nil
                    }

                    // Collect session .jsonl files based on provider layout
                    var jsonlEntries: [(url: URL, sessionId: String)] = []

                    if currentProvider.usesAgentTranscripts {
                        // Cursor layout: agent-transcripts/<sessionId>/<sessionId>.jsonl
                        let transcriptsDir = dirURL.appendingPathComponent("agent-transcripts")
                        if let sessionDirs = try? fm.contentsOfDirectory(atPath: transcriptsDir.path) {
                            for sessionDir in sessionDirs {
                                let sessionDirURL = transcriptsDir.appendingPathComponent(sessionDir)
                                let jsonlFile = sessionDirURL.appendingPathComponent("\(sessionDir).jsonl")
                                if fm.fileExists(atPath: jsonlFile.path) {
                                    jsonlEntries.append((jsonlFile, sessionDir))
                                }
                            }
                        }
                    } else {
                        // Claude Code layout: <sessionId>.jsonl at top level
                        for name in topFiles {
                            if name.hasSuffix(".jsonl") {
                                let sid = String(name.dropLast(6))
                                jsonlEntries.append((dirURL.appendingPathComponent(name), sid))
                            }
                            // Check for subagent files inside session subdirectories
                            let subagentsDir = dirURL.appendingPathComponent(name).appendingPathComponent("subagents")
                            if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsDir.path) {
                                for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                                    let subId = String(subFile.dropLast(6))
                                    jsonlEntries.append((subagentsDir.appendingPathComponent(subFile), subId))
                                }
                            }
                        }
                    }

                    if jsonlEntries.isEmpty { return nil }

                    var sessions: [SessionSummary] = []

                    for entry in jsonlEntries {
                        do {
                            let summary = try await parser.parseMetadata(
                                url: entry.url,
                                sessionId: entry.sessionId,
                                pricingTable: pricingTable
                            )
                            sessions.append(summary)
                        } catch {
                            // Skip unreadable files
                            continue
                        }
                    }

                    // Sort by most recent first
                    sessions.sort { a, b in
                        if a.lastTimestamp.isEmpty && b.lastTimestamp.isEmpty { return false }
                        if a.lastTimestamp.isEmpty { return false }
                        if b.lastTimestamp.isEmpty { return true }
                        return a.lastTimestamp > b.lastTimestamp
                    }

                    return (dirName, sessions)
                }
            }

            for await result in group {
                guard let (dirName, sessions) = result else { continue }

                let project = Project(
                    id: dirName,
                    name: decodeProjectName(dirName),
                    path: projectsDir.appendingPathComponent(dirName).path,
                    sessionCount: sessions.count
                )

                projects.append(project)
                sessionsByProject[dirName] = sessions
            }
        }

        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (projects, sessionsByProject)
    }
}

/// Decode an encoded project directory name into a human-readable project name.
/// Example: `-Users-liranb-projects-agent-hive` -> `agent-hive`
func decodeProjectName(_ encodedName: String) -> String {
    let segments = encodedName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)

    var startIndex = 0

    // Look for "projects" keyword and take everything after it
    if let projectsIndex = segments.lastIndex(of: "projects"),
       projectsIndex + 1 < segments.count {
        startIndex = projectsIndex + 1
    } else if segments.count > 2,
              segments[0].lowercased() == "users" || segments[0].lowercased() == "home" {
        startIndex = 2
    }

    let meaningful = Array(segments[startIndex...])
    return meaningful.isEmpty ? encodedName : meaningful.joined(separator: "-")
}
