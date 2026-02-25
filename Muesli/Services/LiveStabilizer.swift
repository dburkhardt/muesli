import Foundation

/// Deterministic overlap suppressor for live transcription.
/// Keeps a short pending window and emits committed segments plus a draft tail.
actor LiveStabilizer {
    struct DraftUpdate: Sendable {
        let text: String
        let speaker: TranscriptionService.TranscriptSegment.Speaker
    }

    struct Output: Sendable {
        let committedSegments: [TranscriptionService.TranscriptSegment]
        let draftUpdate: DraftUpdate?
    }

    private struct Hypothesis: Sendable {
        let words: [String]
        let timestamp: TimeInterval
    }

    private struct SpeakerState: Sendable {
        var pending: [Hypothesis] = []
        var committedTail: [String] = []
        var lastDraftText: String = ""
        var lastDraftEmitAt: Date = .distantPast
        var duplicateDrops: Int = 0
        var draftRewrites: Int = 0
        var committedCount: Int = 0
    }

    private var stateBySpeaker: [TranscriptionService.TranscriptSegment.Speaker: SpeakerState] = [:]

    private let agreementWindow: Int
    private let overlapDuration: TimeInterval
    private let jitterMargin: TimeInterval
    private let maxDraftTokens: Int
    private let similarityThreshold: Double
    private let draftEmitInterval: TimeInterval

    init(
        agreementWindow: Int = AudioConfiguration.stabilizerAgreementWindow,
        overlapDuration: TimeInterval = AudioConfiguration.transcriptionOverlapDuration,
        jitterMs: Int = AudioConfiguration.stabilizerJitterMs,
        maxDraftTokens: Int = AudioConfiguration.stabilizerMaxDraftTokens,
        similarityThreshold: Double = AudioConfiguration.stabilizerSimilarityThreshold,
        draftEmitIntervalMs: Int = AudioConfiguration.stabilizerDraftEmitIntervalMs
    ) {
        self.agreementWindow = max(1, agreementWindow)
        self.overlapDuration = overlapDuration
        self.jitterMargin = Double(max(0, jitterMs)) / 1000.0
        self.maxDraftTokens = max(1, maxDraftTokens)
        self.similarityThreshold = similarityThreshold
        self.draftEmitInterval = Double(max(0, draftEmitIntervalMs)) / 1000.0
    }

    func ingest(_ segment: TranscriptionService.TranscriptSegment) async -> Output {
        var speakerState = stateBySpeaker[segment.speaker] ?? SpeakerState()
        let rawWords = tokenize(segment.text)
        guard !rawWords.isEmpty else {
            return Output(committedSegments: [], draftUpdate: nil)
        }

        let contextWords = Array((speakerState.committedTail + (speakerState.pending.last?.words ?? [])).suffix(64))
        let dedupedWords = dropOverlapPrefix(incoming: rawWords, context: contextWords, similarityThreshold: similarityThreshold)
        if dedupedWords.count < rawWords.count {
            speakerState.duplicateDrops += (rawWords.count - dedupedWords.count)
        }
        guard !dedupedWords.isEmpty else {
            stateBySpeaker[segment.speaker] = speakerState
            return Output(committedSegments: [], draftUpdate: nil)
        }

        speakerState.pending.append(Hypothesis(words: dedupedWords, timestamp: segment.timestamp))
        let commitBefore = segment.timestamp + AudioConfiguration.transcriptionChunkDuration - overlapDuration - jitterMargin

        var committedSegments: [TranscriptionService.TranscriptSegment] = []
        while speakerState.pending.count >= agreementWindow,
              let head = speakerState.pending.first,
              head.timestamp <= commitBefore {
            let committedWords = dropOverlapPrefix(
                incoming: head.words,
                context: speakerState.committedTail,
                similarityThreshold: similarityThreshold
            )
            speakerState.pending.removeFirst()
            guard !committedWords.isEmpty else { continue }

            speakerState.committedTail.append(contentsOf: committedWords)
            speakerState.committedTail = Array(speakerState.committedTail.suffix(maxDraftTokens * 3))
            speakerState.committedCount += 1

            committedSegments.append(
                TranscriptionService.TranscriptSegment(
                    text: committedWords.joined(separator: " "),
                    timestamp: head.timestamp,
                    speaker: segment.speaker
                )
            )
        }

        let draftWords = speakerState.pending.flatMap(\.words)
        let draftText = draftWords.suffix(maxDraftTokens).joined(separator: " ")
        let shouldEmitDraft = shouldEmitDraft(now: Date(), draftText: draftText, speakerState: speakerState)
        let draftUpdate: DraftUpdate?
        if shouldEmitDraft {
            if speakerState.lastDraftText != draftText {
                speakerState.draftRewrites += 1
            }
            speakerState.lastDraftText = draftText
            speakerState.lastDraftEmitAt = Date()
            draftUpdate = DraftUpdate(text: draftText, speaker: segment.speaker)
        } else {
            draftUpdate = nil
        }

        stateBySpeaker[segment.speaker] = speakerState
        await DiagnosticLogger.shared.log(
            .stabilizer,
            "committed=\(speakerState.committedCount) draftRewrites=\(speakerState.draftRewrites) duplicateDrops=\(speakerState.duplicateDrops)"
        )
        return Output(committedSegments: committedSegments, draftUpdate: draftUpdate)
    }

    func flushAll() async -> Output {
        var committedSegments: [TranscriptionService.TranscriptSegment] = []
        var finalDraft: DraftUpdate?

        for (speaker, var speakerState) in stateBySpeaker {
            while let head = speakerState.pending.first {
                let committedWords = dropOverlapPrefix(
                    incoming: head.words,
                    context: speakerState.committedTail,
                    similarityThreshold: similarityThreshold
                )
                speakerState.pending.removeFirst()
                guard !committedWords.isEmpty else { continue }

                speakerState.committedTail.append(contentsOf: committedWords)
                speakerState.committedTail = Array(speakerState.committedTail.suffix(maxDraftTokens * 3))
                speakerState.committedCount += 1
                committedSegments.append(
                    TranscriptionService.TranscriptSegment(
                        text: committedWords.joined(separator: " "),
                        timestamp: head.timestamp,
                        speaker: speaker
                    )
                )
            }

            speakerState.lastDraftText = ""
            speakerState.lastDraftEmitAt = Date()
            finalDraft = DraftUpdate(text: "", speaker: speaker)
            stateBySpeaker[speaker] = speakerState
            await DiagnosticLogger.shared.log(
                .stabilizer,
                "committed=\(speakerState.committedCount) draftRewrites=\(speakerState.draftRewrites) duplicateDrops=\(speakerState.duplicateDrops)"
            )
        }

        return Output(committedSegments: committedSegments.sorted { $0.timestamp < $1.timestamp }, draftUpdate: finalDraft)
    }

    private func shouldEmitDraft(now: Date, draftText: String, speakerState: SpeakerState) -> Bool {
        if draftText != speakerState.lastDraftText {
            return now.timeIntervalSince(speakerState.lastDraftEmitAt) >= draftEmitInterval
        }
        return false
    }
}

private func tokenize(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

private func dropOverlapPrefix(incoming: [String], context: [String], similarityThreshold: Double) -> [String] {
    guard !incoming.isEmpty, !context.isEmpty else { return incoming }

    let maxOverlap = min(incoming.count, min(context.count, 24))
    var bestOverlap = 0

    for overlap in stride(from: maxOverlap, through: 1, by: -1) {
        let contextSlice = Array(context.suffix(overlap)).map { $0.lowercased() }
        let incomingSlice = Array(incoming.prefix(overlap)).map { $0.lowercased() }
        let similarity = levenshteinSimilarity(contextSlice.joined(separator: " "), incomingSlice.joined(separator: " "))
        if similarity >= similarityThreshold {
            bestOverlap = overlap
            break
        }
    }

    if bestOverlap == 0 { return incoming }
    return Array(incoming.dropFirst(bestOverlap))
}

private func levenshteinSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let distance = levenshteinDistance(Array(lhs), Array(rhs))
    let maxLen = max(lhs.count, rhs.count)
    guard maxLen > 0 else { return 1.0 }
    return 1.0 - Double(distance) / Double(maxLen)
}

private func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
    if lhs.isEmpty { return rhs.count }
    if rhs.isEmpty { return lhs.count }

    var previous = Array(0...rhs.count)
    for (i, lch) in lhs.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: rhs.count)
        for (j, rch) in rhs.enumerated() {
            let substitutionCost = lch == rch ? 0 : 1
            current[j + 1] = min(
                previous[j + 1] + 1,      // deletion
                current[j] + 1,            // insertion
                previous[j] + substitutionCost // substitution
            )
        }
        previous = current
    }
    return previous[rhs.count]
}
