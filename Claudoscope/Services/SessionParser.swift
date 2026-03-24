import Foundation

/// Stream-parses Claude Code JSONL session files.
/// Port of server/services/session-parser.ts
actor SessionParser {
    private let decoder = JSONDecoder()
    private var seenUUIDs = Set<String>()

    /// Clear seen UUIDs (call before a full rescan)
    func resetDedup() {
        seenUUIDs.removeAll()
    }

    /// Full parse of a JSONL session file into a ParsedSession
    func parse(url: URL, sessionId: String) throws -> ParsedSession {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SessionParserError.invalidEncoding
        }

        var records: [ParsedRecordRaw] = []
        var toolResultMap: [String: ToolResultEntry] = [:]
        var modelsSet = Set<String>()

        var firstTimestamp = ""
        var lastTimestamp = ""
        var messageCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheCreationTokens = 0
        var compactionCount = 0
        var parentSessionId: String?
        var slug: String?
        var isFirstRecord = true
        var projectId = ""

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let lineData = trimmed.data(using: .utf8) else { continue }

            let record: ParsedRecordRaw
            do {
                record = try decoder.decode(ParsedRecordRaw.self, from: lineData)
            } catch {
                continue // Skip malformed lines
            }

            // Detect continuation
            if isFirstRecord {
                isFirstRecord = false
                if let recSessionId = record.sessionId, recSessionId != sessionId {
                    parentSessionId = recSessionId
                }
            }

            // Skip records from parent session
            if let parentId = parentSessionId, record.sessionId == parentId {
                continue
            }

            // Skip compact summaries, progress, transcript-only
            if record.isCompactSummary == true { continue }
            if record.effectiveType == .progress { continue }
            if record.isVisibleInTranscriptOnly == true { continue }

            // Capture slug
            if slug == nil, let s = record.slug {
                slug = s
            }

            // Track timestamps
            if let ts = record.timestamp {
                if firstTimestamp.isEmpty { firstTimestamp = ts }
                lastTimestamp = ts
            }

            messageCount += 1

            if record.effectiveType == .user {
                userMessageCount += 1
            }

            if record.effectiveType == .assistant {
                assistantMessageCount += 1

                if record.message?.stopReason != nil, let usage = record.message?.usage {
                    totalInputTokens += usage.inputTokens ?? 0
                    totalOutputTokens += usage.outputTokens ?? 0
                    totalCacheReadTokens += usage.cacheReadInputTokens ?? 0
                    totalCacheCreationTokens += usage.cacheCreationInputTokens ?? 0
                }

                if let model = record.message?.model {
                    modelsSet.insert(model)
                }
            }

            // Compaction boundaries
            if record.effectiveType == .system && record.subtype == "compact_boundary" {
                compactionCount += 1
            }

            // Build tool result map from top-level tool_result records
            if record.effectiveType == .toolResult, let toolUseId = record.toolUseResult?.toolUseId {
                toolResultMap[toolUseId] = ToolResultEntry(
                    content: record.toolUseResult?.content ?? "",
                    isError: record.toolUseResult?.isError ?? false,
                    timestamp: record.timestamp
                )
            }

            // Extract tool_result blocks embedded in user message content arrays
            if record.effectiveType == .user, case .blocks(let blocks) = record.message?.content {
                for block in blocks {
                    if block.type == "tool_result", let toolUseId = block.toolUseId {
                        let resultText: String
                        if let content = block.content {
                            resultText = content.textContent
                        } else {
                            resultText = ""
                        }
                        toolResultMap[toolUseId] = ToolResultEntry(
                            content: resultText,
                            isError: block.isError ?? false,
                            timestamp: record.timestamp
                        )
                    }
                }
            }

            records.append(record)
        }

        // Derive projectId from file path
        let pathComponents = url.pathComponents
        if let projectsIndex = pathComponents.lastIndex(of: "projects"),
           projectsIndex + 1 < pathComponents.count {
            projectId = pathComponents[projectsIndex + 1]
        }

        // Fall back to file dates when JSONL lacks timestamps
        if firstTimestamp.isEmpty || lastTimestamp.isEmpty {
            let fileDates = Self.fileDateTimestamps(url: url)
            if firstTimestamp.isEmpty, let created = fileDates.created {
                firstTimestamp = created
            }
            if lastTimestamp.isEmpty, let modified = fileDates.modified {
                lastTimestamp = modified
            }
        }

        let metadata = SessionMetadata(
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            models: Array(modelsSet),
            compactionCount: compactionCount
        )

        return ParsedSession(
            id: sessionId,
            projectId: projectId,
            slug: slug,
            records: records,
            toolResultMap: toolResultMap,
            metadata: metadata,
            parentSessionId: parentSessionId
        )
    }

    /// Quick metadata extraction for sidebar listing
    func parseMetadata(url: URL, sessionId: String, pricingTable: [String: ModelPricing]) throws -> SessionSummary {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SessionParserError.invalidEncoding
        }

        // Pre-compute file-date fallback for providers without per-record timestamps (e.g. Cursor)
        let fileDates = Self.fileDateTimestamps(url: url)

        let projectId = deriveProjectId(from: url)
        var lineCount = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheCreationTokens = 0
        var modelOutputTokens: [String: Int] = [:]
        var hasError = false
        var slug: String?
        var firstTimestamp = ""
        var lastTimestamp = ""
        var firstLine = ""
        var perMessageCost = 0.0

        // Character counters for token estimation when usage data is absent (Cursor)
        var inputChars = 0
        var outputChars = 0
        var hasUsageData = false

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lineCount += 1

            if lineCount == 1 {
                firstLine = trimmed
            }

            guard let lineData = trimmed.data(using: .utf8) else { continue }

            do {
                let raw = try decoder.decode(ParsedRecordRaw.self, from: lineData)

                if raw.isCompactSummary == true || raw.effectiveType == .progress || raw.isVisibleInTranscriptOnly == true {
                    continue
                }

                if let ts = raw.timestamp {
                    if firstTimestamp.isEmpty { firstTimestamp = ts }
                    lastTimestamp = ts
                }

                if slug == nil, let s = raw.slug {
                    slug = s
                }

                // Accumulate character counts for all messages (used as fallback)
                if let text = raw.message?.content?.textContent {
                    if raw.effectiveType == .user {
                        inputChars += text.count
                    } else if raw.effectiveType == .assistant {
                        outputChars += text.count
                    }
                }

                if raw.effectiveType == .assistant, raw.message?.stopReason != nil, let usage = raw.message?.usage {
                    hasUsageData = true
                    // Deduplicate: skip records already counted from another file
                    if let uuid = raw.uuid {
                        if seenUUIDs.contains(uuid) { continue }
                        seenUUIDs.insert(uuid)
                    }

                    let msgInput = usage.inputTokens ?? 0
                    let msgOutput = usage.outputTokens ?? 0
                    let msgCacheRead = usage.cacheReadInputTokens ?? 0
                    let msgCacheCreate = usage.cacheCreationInputTokens ?? 0

                    // Split cache creation into 5m/1h tiers if available
                    let msgCache5m = usage.cacheCreation?.ephemeral5mInputTokens ?? msgCacheCreate
                    let msgCache1h = usage.cacheCreation?.ephemeral1hInputTokens ?? 0

                    totalInputTokens += msgInput
                    totalOutputTokens += msgOutput
                    totalCacheReadTokens += msgCacheRead
                    totalCacheCreationTokens += msgCacheCreate

                    // Accumulate cost per-message using each message's actual model
                    perMessageCost += estimateCostFromTokens(
                        model: raw.message?.model,
                        inputTokens: msgInput,
                        outputTokens: msgOutput,
                        cacheReadTokens: msgCacheRead,
                        cacheCreation5mTokens: msgCache5m,
                        cacheCreation1hTokens: msgCache1h,
                        table: pricingTable
                    )

                    if let model = raw.message?.model {
                        modelOutputTokens[model, default: 0] += msgOutput
                    }
                }

                if raw.effectiveType == .result, raw.message?.stopReason == "error" {
                    hasError = true
                }

                if raw.effectiveType == .toolResult, raw.toolUseResult?.isError == true {
                    hasError = true
                }
            } catch {
                continue
            }
        }

        // Cursor sessions: estimate tokens from character counts (~4 chars/token)
        // and apply Cursor MAX mode pricing (API cost + 20% markup)
        if !hasUsageData && (inputChars > 0 || outputChars > 0) {
            let estimatedInput = max(inputChars / 4, 1)
            let estimatedOutput = max(outputChars / 4, 1)
            totalInputTokens = estimatedInput
            totalOutputTokens = estimatedOutput

            // Use sonnet pricing as default for Cursor (most common model)
            let baseCost = estimateCostFromTokens(
                model: "sonnet",
                inputTokens: estimatedInput,
                outputTokens: estimatedOutput,
                cacheReadTokens: 0,
                cacheCreation5mTokens: 0,
                cacheCreation1hTokens: 0,
                table: pricingTable
            )
            // Cursor MAX mode adds 20% markup over API pricing
            perMessageCost = baseCost * 1.20

            modelOutputTokens["cursor-estimated", default: 0] += estimatedOutput
        }

        // Fall back to file creation/modification dates when JSONL lacks timestamps
        if firstTimestamp.isEmpty, let created = fileDates.created {
            firstTimestamp = created
        }
        if lastTimestamp.isEmpty, let modified = fileDates.modified {
            lastTimestamp = modified
        }

        let title = deriveTitle(slug: slug, firstLine: firstLine, sessionId: sessionId)
        let primaryModel = modelOutputTokens.max(by: { $0.value < $1.value })?.key

        return SessionSummary(
            id: sessionId,
            projectId: projectId,
            slug: slug,
            title: title,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: lineCount,
            primaryModel: primaryModel,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            estimatedCost: perMessageCost,
            hasError: hasError
        )
    }

    private func deriveProjectId(from url: URL) -> String {
        let components = url.pathComponents
        if let idx = components.lastIndex(of: "projects"), idx + 1 < components.count {
            return components[idx + 1]
        }
        return "unknown"
    }

    private func deriveTitle(slug: String?, firstLine: String, sessionId: String) -> String {
        if let slug { return slug }

        if let data = firstLine.data(using: .utf8),
           let raw = try? decoder.decode(ParsedRecordRaw.self, from: data),
           raw.effectiveType == .user,
           let content = raw.message?.content {

            var text = content.textContent
            // Strip Cursor's <user_query> wrapper tags
            if text.contains("<user_query>") {
                text = text
                    .replacingOccurrences(of: "<user_query>", with: "")
                    .replacingOccurrences(of: "</user_query>", with: "")
            }
            if !text.isEmpty {
                let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if cleaned.count > 80 {
                    return String(cleaned.prefix(80)) + "..."
                }
                return cleaned
            }
        }

        return String(sessionId.prefix(8))
    }

    /// Returns ISO 8601 timestamps derived from the file's creation and modification dates.
    static func fileDateTimestamps(url: URL) -> (created: String?, modified: String?) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return (nil, nil)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let created = (attrs[.creationDate] as? Date).map { formatter.string(from: $0) }
        let modified = (attrs[.modificationDate] as? Date).map { formatter.string(from: $0) }
        return (created, modified)
    }
}

enum SessionParserError: Error {
    case invalidEncoding
    case fileNotFound
}
