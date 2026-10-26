import Combine
import CoreMedia
import Foundation
import Security

@MainActor
final class QwenAPIKeyStore: ObservableObject {
    static let shared = QwenAPIKeyStore()

    @Published private(set) var hasAPIKey: Bool

    var apiKey: String? {
        try? QwenAPIKeychainBackend.read()
    }

    private init() {
        hasAPIKey = (try? QwenAPIKeychainBackend.read()) != nil
    }

    func save(_ apiKey: String) throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.hasPrefix("sk-"),
              !normalizedKey.contains("\r"),
              !normalizedKey.contains("\n") else {
            throw QwenAPIKeyStoreError.invalidAPIKey
        }

        try QwenAPIKeychainBackend.save(normalizedKey)
        hasAPIKey = true
    }

    func delete() {
        try? QwenAPIKeychainBackend.delete()
        hasAPIKey = (try? QwenAPIKeychainBackend.read()) != nil
    }
}

enum QwenAPIKeyStoreError: LocalizedError, Equatable, Sendable {
    case invalidAPIKey
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return String(localized: "请输入有效的 Qwen ASR API Key。")
        case .keychainFailure:
            return String(localized: "无法访问已保存的 Qwen ASR API Key。")
        }
    }
}

private enum QwenAPIKeychainBackend {
    private static let account = "qwen-asr-api-key"

    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "Teleprompter").qwen-asr"
    }

    static func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            if status == errSecSuccess {
                return nil
            }
            throw QwenAPIKeyStoreError.keychainFailure(status)
        }
        return key
    }

    static func save(_ apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw QwenAPIKeyStoreError.invalidAPIKey
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateAttributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw QwenAPIKeyStoreError.keychainFailure(updateStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw QwenAPIKeyStoreError.keychainFailure(addStatus)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QwenAPIKeyStoreError.keychainFailure(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum QwenASRSubtitleTranscriptionError: LocalizedError, Equatable, Sendable {
    case apiKeyMissing
    case audioFileNotFound
    case audioFileTooLarge
    case networkFailure
    case serviceRejectedRequest(statusCode: Int)
    case serviceTaskFailed(code: String?)
    case taskTimedOut
    case invalidServiceResponse
    case insecureResultURL
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return String(localized: "未配置 Qwen ASR API Key。")
        case .audioFileNotFound:
            return String(localized: "找不到需要上传给 Qwen ASR 的音频文件。")
        case .audioFileTooLarge:
            return String(localized: "音频文件超过 Qwen ASR 当前允许的上传大小。")
        case .networkFailure:
            return String(localized: "连接 Qwen ASR 服务失败，请检查网络后重试。")
        case .serviceRejectedRequest(let statusCode):
            return String.localizedStringWithFormat(
                String(localized: "Qwen ASR 请求失败（HTTP %d）。"),
                statusCode
            )
        case .serviceTaskFailed(let code):
            guard let code else {
                return String(localized: "Qwen ASR 识别任务失败。")
            }
            return String.localizedStringWithFormat(
                String(localized: "Qwen ASR 识别任务失败（%@）。"),
                code
            )
        case .taskTimedOut:
            return String(localized: "Qwen ASR 识别超时，请稍后重试。")
        case .invalidServiceResponse:
            return String(localized: "Qwen ASR 返回了无法解析的结果。")
        case .insecureResultURL:
            return String(localized: "Qwen ASR 返回了不安全的结果地址。")
        case .emptyTranscript:
            return String(localized: "Qwen ASR 没有识别到有效字幕。")
        }
    }
}

/// 将同一份字幕音轨上传到 Qwen 云端，并把服务端时间戳映射回源视频时间轴。
final class QwenASRSubtitleTranscriber: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SubtitleTranscriptionProgress) -> Void

    static let shared = QwenASRSubtitleTranscriber()
    static let modelIdentifier = "qwen-audio-3.1-asr-flash-filetrans"

    private static let apiBaseURL = URL(string: "https://dashscope.aliyuncs.com/api/v1")!
    private static let pollingIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let maximumPollingDuration: TimeInterval = 30 * 60
    private static let maximumCharactersPerCue = 18
    private static let maximumDurationPerCue: TimeInterval = 6

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func transcribeAudio(
        at audioURL: URL,
        timelineOffset: CMTime,
        apiKey: String,
        progress: ProgressHandler? = nil
    ) async throws -> SubtitleTranscriptionResult {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.hasPrefix("sk-"),
              !normalizedKey.contains("\r"),
              !normalizedKey.contains("\n") else {
            throw QwenASRSubtitleTranscriptionError.apiKeyMissing
        }
        guard audioURL.isFileURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            throw QwenASRSubtitleTranscriptionError.audioFileNotFound
        }

        progress?(SubtitleTranscriptionProgress(
            phase: .checkingAvailability,
            fractionCompleted: 0
        ))
        try Task.checkCancellation()

        progress?(transcriptionProgress(0.02))
        let policy = try await requestUploadPolicy(apiKey: normalizedKey)
        try validateAudioSize(at: audioURL, policy: policy)
        progress?(transcriptionProgress(0.08))

        let upload = try makeMultipartUpload(audioURL: audioURL, policy: policy)
        defer { try? FileManager.default.removeItem(at: upload.bodyURL) }
        let uploadedFileURL = try await uploadAudio(
            upload,
            progress: { fraction in
                progress?(self.transcriptionProgress(0.08 + fraction * 0.34))
            }
        )

        try Task.checkCancellation()
        progress?(transcriptionProgress(0.45))
        let taskID = try await submitTask(
            uploadedFileURL: uploadedFileURL,
            apiKey: normalizedKey
        )
        progress?(transcriptionProgress(0.52))

        let resultURL = try await waitForResult(
            taskID: taskID,
            apiKey: normalizedKey,
            progress: progress
        )
        try Task.checkCancellation()
        progress?(transcriptionProgress(0.94))

        let transcript = try await downloadTranscript(from: resultURL)
        let offsetSeconds = timelineOffset.seconds.isFinite
            ? max(timelineOffset.seconds, 0)
            : 0
        let cues = makeCues(from: transcript, timelineOffset: offsetSeconds)
        guard !cues.isEmpty else {
            throw QwenASRSubtitleTranscriptionError.emptyTranscript
        }

        progress?(SubtitleTranscriptionProgress(
            phase: .completed,
            fractionCompleted: 1
        ))
        return SubtitleTranscriptionResult(
            cues: cues,
            metadata: SubtitleRecognitionMetadata(
                provider: .qwen,
                modelIdentifier: Self.modelIdentifier
            )
        )
    }

    private func requestUploadPolicy(apiKey: String) async throws -> UploadPolicy {
        var components = URLComponents(
            url: Self.apiBaseURL.appendingPathComponent("uploads"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: Self.modelIdentifier)
        ]
        guard let url = components?.url else {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await responseData(for: request)

        do {
            return try JSONDecoder().decode(UploadPolicyEnvelope.self, from: data).data
        } catch {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }
    }

    private func validateAudioSize(at audioURL: URL, policy: UploadPolicy) throws {
        guard let maximumSize = policy.maximumFileSizeMegabytes else { return }
        let values = try audioURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else { return }
        let maximumBytes = Int64(maximumSize) * 1_000_000
        guard Int64(fileSize) <= maximumBytes else {
            throw QwenASRSubtitleTranscriptionError.audioFileTooLarge
        }
    }

    private func makeMultipartUpload(
        audioURL: URL,
        policy: UploadPolicy
    ) throws -> MultipartUpload {
        guard let uploadURL = secureAlibabaURL(from: policy.uploadHost) else {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeleprompterQwenASR", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let identifier = UUID().uuidString
        let filename = "\(identifier).m4a"
        let objectKey = "\(policy.uploadDirectory)/\(filename)"
        let boundary = "Teleprompter-\(identifier)"
        let bodyURL = directory
            .appendingPathComponent(identifier)
            .appendingPathExtension("multipart")

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw QwenASRSubtitleTranscriptionError.networkFailure
        }

        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }

            let fields: [(String, String)] = [
                ("OSSAccessKeyId", policy.ossAccessKeyID),
                ("Signature", policy.signature),
                ("policy", policy.policy),
                ("x-oss-object-acl", policy.objectACL),
                ("x-oss-forbid-overwrite", policy.forbidOverwrite),
                ("key", objectKey),
                ("success_action_status", "200")
            ]
            for (name, value) in fields {
                try write(
                    "--\(boundary)\r\n"
                        + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                        + "\(sanitizedMultipartValue(value))\r\n",
                    to: output
                )
            }

            try write(
                "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                    + "Content-Type: audio/mp4\r\n\r\n",
                to: output
            )
            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1_048_576),
                      !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try write("\r\n--\(boundary)--\r\n", to: output)
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        return MultipartUpload(
            uploadURL: uploadURL,
            bodyURL: bodyURL,
            contentType: "multipart/form-data; boundary=\(boundary)",
            objectURL: "oss://\(objectKey)"
        )
    }

    private func uploadAudio(
        _ upload: MultipartUpload,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        var request = URLRequest(url: upload.uploadURL)
        request.httpMethod = "POST"
        request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(progress: progress)
        do {
            let (_, response) = try await session.upload(
                for: request,
                fromFile: upload.bodyURL,
                delegate: delegate
            )
            try validate(response)
            progress(1)
            return upload.objectURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QwenASRSubtitleTranscriptionError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw QwenASRSubtitleTranscriptionError.networkFailure
        }
    }

    private func submitTask(
        uploadedFileURL: String,
        apiKey: String
    ) async throws -> String {
        let endpoint = Self.apiBaseURL
            .appendingPathComponent("services")
            .appendingPathComponent("audio")
            .appendingPathComponent("asr")
            .appendingPathComponent("transcription")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        request.httpBody = try JSONEncoder().encode(SubmitTaskRequest(
            model: Self.modelIdentifier,
            input: .init(fileURLs: [uploadedFileURL]),
            parameters: .init(
                channelID: [0],
                languageHints: ["zh"],
                keepDialect: false
            )
        ))

        let data = try await responseData(for: request)
        do {
            let response = try JSONDecoder().decode(TaskEnvelope.self, from: data)
            guard let taskID = response.output?.taskID, !taskID.isEmpty else {
                throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
            }
            return taskID
        } catch let error as QwenASRSubtitleTranscriptionError {
            throw error
        } catch {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }
    }

    private func waitForResult(
        taskID: String,
        apiKey: String,
        progress: ProgressHandler?
    ) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await pollForResult(
                taskID: taskID,
                apiKey: apiKey,
                progress: progress
            )
        }, onCancel: {
            Task.detached(priority: .utility) {
                await Self.cancelPendingTask(taskID: taskID, apiKey: apiKey)
            }
        })
    }

    private func pollForResult(
        taskID: String,
        apiKey: String,
        progress: ProgressHandler?
    ) async throws -> URL {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var pollCount = 0

        while ProcessInfo.processInfo.systemUptime - startedAt
                < Self.maximumPollingDuration {
            try Task.checkCancellation()
            let endpoint = Self.apiBaseURL
                .appendingPathComponent("tasks")
                .appendingPathComponent(taskID)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let data = try await responseData(for: request)
            let envelope: TaskEnvelope
            do {
                envelope = try JSONDecoder().decode(TaskEnvelope.self, from: data)
            } catch {
                throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
            }
            guard let output = envelope.output else {
                throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
            }

            switch output.taskStatus.uppercased() {
            case "PENDING", "RUNNING":
                pollCount += 1
                progress?(transcriptionProgress(
                    min(0.9, 0.54 + Double(pollCount) * 0.015)
                ))
                try await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds)

            case "SUCCEEDED":
                guard let result = output.results?.first else {
                    throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
                }
                guard result.subtaskStatus.uppercased() == "SUCCEEDED" else {
                    throw QwenASRSubtitleTranscriptionError.serviceTaskFailed(
                        code: sanitizedServiceCode(result.code)
                    )
                }
                guard let value = result.transcriptionURL else {
                    throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
                }
                guard let url = secureAlibabaURL(from: value) else {
                    throw QwenASRSubtitleTranscriptionError.insecureResultURL
                }
                return url

            case "FAILED", "UNKNOWN":
                throw QwenASRSubtitleTranscriptionError.serviceTaskFailed(
                    code: sanitizedServiceCode(output.code)
                )

            default:
                throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
            }
        }

        throw QwenASRSubtitleTranscriptionError.taskTimedOut
    }

    private static func cancelPendingTask(taskID: String, apiKey: String) async {
        let endpoint = apiBaseURL
            .appendingPathComponent("tasks")
            .appendingPathComponent(taskID)
            .appendingPathComponent("cancel")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let cancellationSession = URLSession(configuration: configuration)
        defer { cancellationSession.finishTasksAndInvalidate() }
        _ = try? await cancellationSession.data(for: request)
    }

    private func downloadTranscript(from url: URL) async throws -> TranscriptFile {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(TranscriptFile.self, from: data)
        } catch {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QwenASRSubtitleTranscriptionError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw QwenASRSubtitleTranscriptionError.networkFailure
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw QwenASRSubtitleTranscriptionError.serviceRejectedRequest(
                statusCode: response.statusCode
            )
        }
    }

    private func makeCues(
        from transcript: TranscriptFile,
        timelineOffset: TimeInterval
    ) -> [SubtitleCue] {
        guard let channel = transcript.transcripts.first(where: { $0.channelID == 0 })
                ?? transcript.transcripts.first else { return [] }

        return channel.sentences
            .flatMap { makeCues(from: $0, timelineOffset: timelineOffset) }
            .filter(\.isValid)
            .sorted { CMTimeCompare($0.startTime, $1.startTime) < 0 }
    }

    private func makeCues(
        from sentence: TranscriptSentence,
        timelineOffset: TimeInterval
    ) -> [SubtitleCue] {
        let sentenceStart = timelineOffset + max(Double(sentence.beginTime) / 1_000, 0)
        let sentenceEnd = timelineOffset + max(Double(sentence.endTime) / 1_000, 0)
        guard sentenceEnd > sentenceStart else { return [] }

        let timedWords = sentence.words.compactMap { word -> TimedWord? in
            let text = word.text + (word.punctuation ?? "")
            let start = timelineOffset + max(Double(word.beginTime) / 1_000, 0)
            let end = timelineOffset + max(Double(word.endTime) / 1_000, 0)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  end > start else { return nil }
            return TimedWord(text: text, start: start, end: end)
        }
        guard !timedWords.isEmpty else {
            return makeProportionalCues(
                text: sentence.text,
                start: sentenceStart,
                end: sentenceEnd
            )
        }

        var cues: [SubtitleCue] = []
        var currentText = ""
        var cueStart = timedWords[0].start
        var cueEnd = timedWords[0].end

        func flush() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cue = SubtitleCue(
                startSeconds: cueStart,
                endSeconds: max(cueEnd, cueStart + 0.08),
                text: text
            ), !text.isEmpty {
                cues.append(cue)
            }
            currentText = ""
        }

        for word in timedWords {
            if currentText.isEmpty {
                cueStart = word.start
                cueEnd = word.end
            }

            let wouldExceedLength = currentText.count + word.text.count
                > Self.maximumCharactersPerCue
            let wouldExceedDuration = word.end - cueStart
                > Self.maximumDurationPerCue
            if !currentText.isEmpty && (wouldExceedLength || wouldExceedDuration) {
                flush()
                cueStart = word.start
            }

            currentText += word.text
            cueEnd = max(cueEnd, word.end)
            let endsSentence = word.text.last.map { "。！？!?；;".contains($0) } ?? false
            if endsSentence
                || currentText.count >= Self.maximumCharactersPerCue
                || cueEnd - cueStart >= Self.maximumDurationPerCue {
                flush()
            }
        }
        flush()
        return cues
    }

    private func makeProportionalCues(
        text rawText: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> [SubtitleCue] {
        let characters = Array(
            rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !characters.isEmpty, end > start else { return [] }

        var cues: [SubtitleCue] = []
        var index = 0
        while index < characters.count {
            let nextIndex = min(index + Self.maximumCharactersPerCue, characters.count)
            let startFraction = Double(index) / Double(characters.count)
            let endFraction = Double(nextIndex) / Double(characters.count)
            if let cue = SubtitleCue(
                startSeconds: start + (end - start) * startFraction,
                endSeconds: start + (end - start) * endFraction,
                text: String(characters[index..<nextIndex])
            ) {
                cues.append(cue)
            }
            index = nextIndex
        }
        return cues
    }

    private func transcriptionProgress(_ fraction: Double) -> SubtitleTranscriptionProgress {
        SubtitleTranscriptionProgress(
            phase: .transcribing,
            fractionCompleted: fraction
        )
    }

    private func secureAlibabaURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              host == "aliyuncs.com" || host.hasSuffix(".aliyuncs.com") else {
            return nil
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        return components.url
    }

    private func sanitizedMultipartValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func sanitizedServiceCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.filter { allowed.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars)).prefix(64)
        return sanitized.isEmpty ? nil : String(sanitized)
    }

    private func write(_ value: String, to handle: FileHandle) throws {
        guard let data = value.data(using: .utf8) else {
            throw QwenASRSubtitleTranscriptionError.invalidServiceResponse
        }
        try handle.write(contentsOf: data)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(
            min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
        )
    }
}

private struct MultipartUpload {
    let uploadURL: URL
    let bodyURL: URL
    let contentType: String
    let objectURL: String
}

private struct UploadPolicyEnvelope: Decodable {
    let data: UploadPolicy
}

private struct UploadPolicy: Decodable {
    let policy: String
    let signature: String
    let uploadDirectory: String
    let uploadHost: String
    let maximumFileSizeMegabytes: Int?
    let ossAccessKeyID: String
    let objectACL: String
    let forbidOverwrite: String

    private enum CodingKeys: String, CodingKey {
        case policy
        case signature
        case uploadDirectory = "upload_dir"
        case uploadHost = "upload_host"
        case maximumFileSizeMegabytes = "max_file_size_mb"
        case ossAccessKeyID = "oss_access_key_id"
        case objectACL = "x_oss_object_acl"
        case forbidOverwrite = "x_oss_forbid_overwrite"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(String.self, forKey: .policy)
        signature = try container.decode(String.self, forKey: .signature)
        uploadDirectory = try container.decode(String.self, forKey: .uploadDirectory)
        uploadHost = try container.decode(String.self, forKey: .uploadHost)
        ossAccessKeyID = try container.decode(String.self, forKey: .ossAccessKeyID)
        objectACL = try container.decode(String.self, forKey: .objectACL)
        forbidOverwrite = try container.decode(String.self, forKey: .forbidOverwrite)
        if let integer = try? container.decode(Int.self, forKey: .maximumFileSizeMegabytes) {
            maximumFileSizeMegabytes = integer
        } else if let string = try? container.decode(
            String.self,
            forKey: .maximumFileSizeMegabytes
        ) {
            maximumFileSizeMegabytes = Int(string)
        } else {
            maximumFileSizeMegabytes = nil
        }
    }
}

private struct SubmitTaskRequest: Encodable {
    struct Input: Encodable {
        let fileURLs: [String]

        private enum CodingKeys: String, CodingKey {
            case fileURLs = "file_urls"
        }
    }

    struct Parameters: Encodable {
        let channelID: [Int]
        let languageHints: [String]
        let keepDialect: Bool

        private enum CodingKeys: String, CodingKey {
            case channelID = "channel_id"
            case languageHints = "language_hints"
            case keepDialect = "keep_dialect"
        }
    }

    let model: String
    let input: Input
    let parameters: Parameters
}

private struct TaskEnvelope: Decodable {
    let output: TaskOutput?
}

private struct TaskOutput: Decodable {
    let taskID: String?
    let taskStatus: String
    let results: [TaskResult]?
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case taskStatus = "task_status"
        case results
        case code
    }
}

private struct TaskResult: Decodable {
    let subtaskStatus: String
    let transcriptionURL: String?
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case subtaskStatus = "subtask_status"
        case transcriptionURL = "transcription_url"
        case code
    }
}

private struct TranscriptFile: Decodable {
    let transcripts: [TranscriptChannel]
}

private struct TranscriptChannel: Decodable {
    let channelID: Int
    let sentences: [TranscriptSentence]

    private enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case sentences
    }
}

private struct TranscriptSentence: Decodable {
    let beginTime: Int64
    let endTime: Int64
    let text: String
    let words: [TranscriptWord]

    private enum CodingKeys: String, CodingKey {
        case beginTime = "begin_time"
        case endTime = "end_time"
        case text
        case words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beginTime = try container.decode(Int64.self, forKey: .beginTime)
        endTime = try container.decode(Int64.self, forKey: .endTime)
        text = try container.decode(String.self, forKey: .text)
        words = try container.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
    }
}

private struct TranscriptWord: Decodable {
    let beginTime: Int64
    let endTime: Int64
    let text: String
    let punctuation: String?

    private enum CodingKeys: String, CodingKey {
        case beginTime = "begin_time"
        case endTime = "end_time"
        case text
        case punctuation
    }
}

private struct TimedWord {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}
