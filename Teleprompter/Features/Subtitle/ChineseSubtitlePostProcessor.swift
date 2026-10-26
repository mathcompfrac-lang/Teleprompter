import Foundation

struct ChineseSubtitleCorrectionResult: Sendable {
    let texts: [String]
    let correctedTokenCount: Int
    let correctedCueCount: Int
    let exactMatchCount: Int
}

enum ChineseSubtitlePostProcessor {
    private struct AlignmentToken {
        let rawText: String
        let normalizedText: String
        let cueIndex: Int?
        let characterOffset: Int?
        let isHan: Bool
    }

    private struct MatchPair {
        let recognizedIndex: Int
        let referenceIndex: Int
    }

    private static let minimumReferenceTokenCount = 12
    private static let minimumRecognizedTokenCount = 8
    private static let minimumExactMatchCount = 8
    private static let minimumRecognizedCoverage = 0.55
    private static let minimumAlignmentDensity = 0.55
    private static let minimumConsecutiveAnchorCount = 4
    private static let maximumAlignmentCellCount = 12_000_000

    static func isSafeReferenceAlternative(
        primaryText: String,
        candidateText: String
    ) -> Bool {
        let primaryTokens = tokens(in: primaryText, cueIndex: nil)
        let candidateTokens = tokens(in: candidateText, cueIndex: nil)
        guard !primaryTokens.isEmpty,
              primaryTokens.count == candidateTokens.count else {
            return false
        }

        var changedTokenCount = 0
        for (primaryToken, candidateToken) in zip(primaryTokens, candidateTokens) {
            if primaryToken.normalizedText == candidateToken.normalizedText {
                continue
            }
            guard primaryToken.isHan,
                  candidateToken.isHan,
                  normalizedPinyin(primaryToken.rawText)
                    == normalizedPinyin(candidateToken.rawText) else {
                return false
            }
            changedTokenCount += 1
        }

        let maximumChangedTokenCount = min(
            4,
            max(1, Int(Double(primaryTokens.count) * 0.15))
        )
        return changedTokenCount <= maximumChangedTokenCount
    }

    static func correct(
        cueTexts: [String],
        referenceText: String
    ) -> ChineseSubtitleCorrectionResult {
        let originalResult = ChineseSubtitleCorrectionResult(
            texts: cueTexts,
            correctedTokenCount: 0,
            correctedCueCount: 0,
            exactMatchCount: 0
        )
        guard !cueTexts.isEmpty else { return originalResult }

        let recognizedTokens = cueTexts.enumerated().flatMap { cueIndex, text in
            tokens(in: text, cueIndex: cueIndex)
        }
        let referenceTokens = tokens(in: referenceText, cueIndex: nil)
        guard recognizedTokens.count >= minimumRecognizedTokenCount,
              referenceTokens.count >= minimumReferenceTokenCount,
              let matches = longestCommonSubsequenceMatches(
                  recognizedTokens,
                  referenceTokens
              ),
              matches.count >= minimumExactMatchCount,
              let firstMatch = matches.first,
              let lastMatch = matches.last else {
            return originalResult
        }

        let recognizedCoverage = Double(matches.count) / Double(recognizedTokens.count)
        let recognizedSpan = lastMatch.recognizedIndex - firstMatch.recognizedIndex + 1
        let referenceSpan = lastMatch.referenceIndex - firstMatch.referenceIndex + 1
        let alignmentDensity = Double(matches.count) / Double(max(recognizedSpan, referenceSpan))
        guard recognizedCoverage >= minimumRecognizedCoverage,
              alignmentDensity >= minimumAlignmentDensity,
              longestConsecutiveMatchCount(in: matches) >= minimumConsecutiveAnchorCount else {
            return ChineseSubtitleCorrectionResult(
                texts: cueTexts,
                correctedTokenCount: 0,
                correctedCueCount: 0,
                exactMatchCount: matches.count
            )
        }

        let maximumHomophoneCorrections = max(
            1,
            Int(Double(recognizedTokens.count) * 0.15)
        )
        var homophoneCorrectionCount = 0
        var replacements: [Int: [Int: String]] = [:]

        guard matches.count >= 2 else {
            return ChineseSubtitleCorrectionResult(
                texts: cueTexts,
                correctedTokenCount: 0,
                correctedCueCount: 0,
                exactMatchCount: matches.count
            )
        }

        for matchIndex in 0..<(matches.count - 1) {
            let leftMatch = matches[matchIndex]
            let rightMatch = matches[matchIndex + 1]
            let recognizedStart = leftMatch.recognizedIndex + 1
            let recognizedEnd = rightMatch.recognizedIndex
            let referenceStart = leftMatch.referenceIndex + 1
            let referenceEnd = rightMatch.referenceIndex
            let recognizedGapCount = recognizedEnd - recognizedStart
            let referenceGapCount = referenceEnd - referenceStart

            guard recognizedGapCount == referenceGapCount,
                  (1...4).contains(recognizedGapCount) else {
                continue
            }

            let recognizedGap = Array(recognizedTokens[recognizedStart..<recognizedEnd])
            let referenceGap = Array(referenceTokens[referenceStart..<referenceEnd])
            guard recognizedGap.allSatisfy(\.isHan),
                  referenceGap.allSatisfy(\.isHan) else {
                continue
            }

            let leftAnchorCount = consecutiveMatchCountEnding(
                at: matchIndex,
                in: matches
            )
            let rightAnchorCount = consecutiveMatchCountStarting(
                at: matchIndex + 1,
                in: matches
            )
            let recognizedGapText = recognizedGap.map(\.rawText).joined()
            let referenceGapText = referenceGap.map(\.rawText).joined()
            guard recognizedGapText != referenceGapText else { continue }

            let isHomophone = normalizedPinyin(recognizedGapText)
                == normalizedPinyin(referenceGapText)
            guard isHomophone,
                  leftAnchorCount >= 2,
                  rightAnchorCount >= 2,
                  alignmentDensity >= 0.65,
                  !hasAmbiguousReferenceGap(
                      recognizedGapText: recognizedGapText,
                      referenceStart: referenceStart,
                      gapCount: referenceGapCount,
                      referenceTokens: referenceTokens
                  ),
                  homophoneCorrectionCount + recognizedGapCount
                    <= maximumHomophoneCorrections else { continue }

            for offset in 0..<recognizedGapCount {
                let recognizedToken = recognizedGap[offset]
                guard let cueIndex = recognizedToken.cueIndex,
                      let characterOffset = recognizedToken.characterOffset else {
                    continue
                }
                replacements[cueIndex, default: [:]][characterOffset]
                    = referenceGap[offset].rawText
            }
            homophoneCorrectionCount += recognizedGapCount
        }

        guard !replacements.isEmpty else {
            return ChineseSubtitleCorrectionResult(
                texts: cueTexts,
                correctedTokenCount: 0,
                correctedCueCount: 0,
                exactMatchCount: matches.count
            )
        }

        let correctedTexts = cueTexts.enumerated().map { cueIndex, text in
            guard let cueReplacements = replacements[cueIndex] else { return text }
            var correctedText = ""
            for (characterOffset, character) in text.enumerated() {
                correctedText.append(
                    contentsOf: cueReplacements[characterOffset] ?? String(character)
                )
            }
            return correctedText
        }
        let correctedTokenCount = replacements.values.reduce(0) { $0 + $1.count }
        return ChineseSubtitleCorrectionResult(
            texts: correctedTexts,
            correctedTokenCount: correctedTokenCount,
            correctedCueCount: replacements.count,
            exactMatchCount: matches.count
        )
    }

    private static func tokens(
        in text: String,
        cueIndex: Int?
    ) -> [AlignmentToken] {
        var result: [AlignmentToken] = []
        var asciiWord = ""
        var asciiWordOffset: Int?

        func flushASCIIWord() {
            guard !asciiWord.isEmpty else { return }
            result.append(AlignmentToken(
                rawText: asciiWord,
                normalizedText: asciiWord.lowercased(),
                cueIndex: cueIndex,
                characterOffset: asciiWordOffset,
                isHan: false
            ))
            asciiWord = ""
            asciiWordOffset = nil
        }

        for (characterOffset, character) in text.enumerated() {
            if isASCIIWordCharacter(character) {
                if asciiWord.isEmpty {
                    asciiWordOffset = characterOffset
                }
                asciiWord.append(character)
                continue
            }

            flushASCIIWord()
            guard character.isLetter || character.isNumber else { continue }
            let rawText = String(character)
            result.append(AlignmentToken(
                rawText: rawText,
                normalizedText: rawText.lowercased(),
                cueIndex: cueIndex,
                characterOffset: characterOffset,
                isHan: isHanCharacter(character)
            ))
        }
        flushASCIIWord()
        return result
    }

    private static func longestCommonSubsequenceMatches(
        _ recognized: [AlignmentToken],
        _ reference: [AlignmentToken]
    ) -> [MatchPair]? {
        let rowCount = recognized.count + 1
        let columnCount = reference.count + 1
        guard rowCount <= maximumAlignmentCellCount / columnCount else { return nil }
        let cellCount = rowCount * columnCount
        guard cellCount <= maximumAlignmentCellCount else { return nil }

        var directions = [UInt8](repeating: 0, count: cellCount)
        var previousRow = [Int](repeating: 0, count: columnCount)
        var currentRow = [Int](repeating: 0, count: columnCount)

        for recognizedIndex in 1..<rowCount {
            currentRow[0] = 0
            for referenceIndex in 1..<columnCount {
                let directionIndex = recognizedIndex * columnCount + referenceIndex
                let upperValue = previousRow[referenceIndex]
                let leftValue = currentRow[referenceIndex - 1]
                if recognized[recognizedIndex - 1].normalizedText
                    == reference[referenceIndex - 1].normalizedText {
                    let diagonalValue = previousRow[referenceIndex - 1] + 1
                    if diagonalValue > max(upperValue, leftValue) {
                        currentRow[referenceIndex] = diagonalValue
                        directions[directionIndex] = 1
                    } else if leftValue >= upperValue {
                        currentRow[referenceIndex] = leftValue
                        directions[directionIndex] = 3
                    } else {
                        currentRow[referenceIndex] = upperValue
                        directions[directionIndex] = 2
                    }
                } else if leftValue >= upperValue {
                    currentRow[referenceIndex] = leftValue
                    directions[directionIndex] = 3
                } else {
                    currentRow[referenceIndex] = upperValue
                    directions[directionIndex] = 2
                }
            }
            swap(&previousRow, &currentRow)
        }

        var matches: [MatchPair] = []
        var recognizedIndex = recognized.count
        var referenceIndex = reference.count
        while recognizedIndex > 0, referenceIndex > 0 {
            let direction = directions[recognizedIndex * columnCount + referenceIndex]
            switch direction {
            case 1:
                matches.append(MatchPair(
                    recognizedIndex: recognizedIndex - 1,
                    referenceIndex: referenceIndex - 1
                ))
                recognizedIndex -= 1
                referenceIndex -= 1
            case 2:
                recognizedIndex -= 1
            case 3:
                referenceIndex -= 1
            default:
                recognizedIndex = 0
                referenceIndex = 0
            }
        }
        return Array(matches.reversed())
    }

    private static func longestConsecutiveMatchCount(in matches: [MatchPair]) -> Int {
        guard !matches.isEmpty else { return 0 }
        var longestCount = 1
        var currentCount = 1
        for index in 1..<matches.count {
            if isConsecutive(matches[index - 1], matches[index]) {
                currentCount += 1
                longestCount = max(longestCount, currentCount)
            } else {
                currentCount = 1
            }
        }
        return longestCount
    }

    private static func consecutiveMatchCountEnding(
        at index: Int,
        in matches: [MatchPair]
    ) -> Int {
        var count = 1
        var currentIndex = index
        while currentIndex > 0,
              isConsecutive(matches[currentIndex - 1], matches[currentIndex]) {
            count += 1
            currentIndex -= 1
        }
        return count
    }

    private static func consecutiveMatchCountStarting(
        at index: Int,
        in matches: [MatchPair]
    ) -> Int {
        var count = 1
        var currentIndex = index
        while currentIndex + 1 < matches.count,
              isConsecutive(matches[currentIndex], matches[currentIndex + 1]) {
            count += 1
            currentIndex += 1
        }
        return count
    }

    private static func isConsecutive(_ lhs: MatchPair, _ rhs: MatchPair) -> Bool {
        rhs.recognizedIndex == lhs.recognizedIndex + 1
            && rhs.referenceIndex == lhs.referenceIndex + 1
    }

    private static func normalizedPinyin(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return latin
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func hasAmbiguousReferenceGap(
        recognizedGapText: String,
        referenceStart: Int,
        gapCount: Int,
        referenceTokens: [AlignmentToken]
    ) -> Bool {
        let anchorCount = 2
        guard referenceStart >= anchorCount,
              gapCount > 0,
              referenceStart + gapCount + anchorCount <= referenceTokens.count else {
            return true
        }

        let leftContext = referenceTokens[(referenceStart - anchorCount)..<referenceStart]
            .map(\.normalizedText)
        let rightStart = referenceStart + gapCount
        let rightContext = referenceTokens[rightStart..<(rightStart + anchorCount)]
            .map(\.normalizedText)
        let recognizedPinyin = normalizedPinyin(recognizedGapText)
        var possibleReferenceGaps: Set<String> = []
        let lastCandidateStart = referenceTokens.count - gapCount - anchorCount

        for candidateStart in anchorCount...lastCandidateStart {
            let candidateEnd = candidateStart + gapCount
            let candidateLeftContext = referenceTokens[
                (candidateStart - anchorCount)..<candidateStart
            ].map(\.normalizedText)
            let candidateRightContext = referenceTokens[
                candidateEnd..<(candidateEnd + anchorCount)
            ].map(\.normalizedText)
            guard candidateLeftContext == leftContext,
                  candidateRightContext == rightContext else {
                continue
            }

            let candidateGap = referenceTokens[candidateStart..<candidateEnd]
            guard candidateGap.allSatisfy(\.isHan) else { continue }
            let candidateGapText = candidateGap.map(\.rawText).joined()
            guard normalizedPinyin(candidateGapText) == recognizedPinyin else { continue }
            possibleReferenceGaps.insert(candidateGapText)
            if possibleReferenceGaps.count > 1 {
                return true
            }
        }
        return false
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }

    private static func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
