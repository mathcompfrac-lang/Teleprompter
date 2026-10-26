import Combine
import CryptoKit
import Foundation

struct SenseVoiceModelFiles: Equatable, Sendable {
    let model: URL
    let tokens: URL
    let vad: URL
}

@MainActor
final class SenseVoiceModelManager: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case verifying
        case ready
        case failed(message: String)

        var isInstalling: Bool {
            switch self {
            case .downloading, .verifying:
                return true
            case .notInstalled, .ready, .failed:
                return false
            }
        }
    }

    static let shared = SenseVoiceModelManager()
    nonisolated static let modelIdentifier = "SenseVoiceSmall-2024-07-17-int8"
    nonisolated static let downloadSizeText = "240 MB"
    nonisolated static let attributionURL = URL(
        string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE"
    )!

    @Published private(set) var state: State

    private struct DownloadSpec: Sendable {
        let remoteURL: URL
        let fileName: String
        let expectedSize: Int64
        let sha256: String
    }

    private struct Manifest: Codable {
        let modelIdentifier: String
        let files: [String: FileRecord]
    }

    private struct FileRecord: Codable {
        let byteCount: Int64
        let sha256: String
    }

    private nonisolated static let modelDirectoryName = "SenseVoiceSmall-2024-07-17-int8"
    private nonisolated static let manifestFileName = "manifest.json"
    private nonisolated static let specs = [
        DownloadSpec(
            remoteURL: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx?download=true")!,
            fileName: "model.int8.onnx",
            expectedSize: 239_233_841,
            sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
        ),
        DownloadSpec(
            remoteURL: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt?download=true")!,
            fileName: "tokens.txt",
            expectedSize: 315_894,
            sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
        ),
        DownloadSpec(
            remoteURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
            fileName: "silero_vad.onnx",
            expectedSize: 643_854,
            sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
        ),
    ]

    private var installationTask: Task<Void, Never>?
    private var installationIdentifier: UUID?

    private init() {
        state = Self.installedFilesIfValid() == nil ? .notInstalled : .ready
    }

    var installedFiles: SenseVoiceModelFiles? {
        guard state == .ready else { return nil }
        return Self.installedFilesIfValid()
    }

    func install() {
        guard installationTask == nil else { return }
        let identifier = UUID()
        installationIdentifier = identifier
        state = .downloading(progress: 0)
        installationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.installationTask = nil
                if self.installationIdentifier == identifier {
                    self.installationIdentifier = nil
                }
            }
            do {
                try await self.installModel(identifier: identifier)
                self.state = .ready
            } catch is CancellationError {
                self.state = Self.installedFilesIfValid() == nil ? .notInstalled : .ready
            } catch {
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancelInstallation() {
        installationTask?.cancel()
    }

    func removeInstalledModel() throws {
        guard !state.isInstalling else {
            throw LocalSubtitleTranscriptionError.modelInstallationFailed(
                String(localized: "模型正在使用，暂时无法删除。")
            )
        }
        let directory = try Self.modelDirectoryURL()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        state = .notInstalled
    }

    private func installModel(identifier: UUID) async throws {
        let fileManager = FileManager.default
        let rootDirectory = try Self.modelsRootURL()
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = rootDirectory
        try? mutableRoot.setResourceValues(resourceValues)

        let stagingDirectory = rootDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let totalBytes = Self.specs.reduce(Int64(0)) { $0 + $1.expectedSize }
        var completedBytes: Int64 = 0

        for spec in Self.specs {
            try Task.checkCancellation()
            let destination = stagingDirectory.appendingPathComponent(spec.fileName)
            let baseCompletedBytes = completedBytes
            let downloader = ModelFileDownloader { [weak self] written, expected in
                let boundedWritten = min(max(written, 0), max(expected, spec.expectedSize))
                let fraction = Double(baseCompletedBytes + boundedWritten) / Double(totalBytes)
                Task { @MainActor [weak self] in
                    guard let self,
                          self.installationIdentifier == identifier,
                          case .downloading(let currentProgress) = self.state else { return }
                    self.state = .downloading(
                        progress: max(currentProgress, min(max(fraction, 0), 0.99))
                    )
                }
            }
            state = .downloading(progress: Double(completedBytes) / Double(totalBytes))
            try await downloader.download(from: spec.remoteURL, to: destination)
            completedBytes += spec.expectedSize
        }

        state = .verifying
        let verificationTask = Task.detached(priority: .utility) {
            for spec in Self.specs {
                try Task.checkCancellation()
                let fileURL = stagingDirectory.appendingPathComponent(spec.fileName)
                try Self.validate(fileURL: fileURL, against: spec)
            }
        }
        try await withTaskCancellationHandler(operation: {
            try await verificationTask.value
        }, onCancel: {
            verificationTask.cancel()
        })
        try Task.checkCancellation()

        let records = Dictionary(uniqueKeysWithValues: Self.specs.map {
            ($0.fileName, FileRecord(byteCount: $0.expectedSize, sha256: $0.sha256))
        })
        let manifest = Manifest(
            modelIdentifier: Self.modelIdentifier,
            files: records
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(
            to: stagingDirectory.appendingPathComponent(Self.manifestFileName),
            options: .atomic
        )
        try Task.checkCancellation()

        let installedDirectory = try Self.modelDirectoryURL()
        let backupDirectory = rootDirectory.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let hadExistingInstallation = fileManager.fileExists(atPath: installedDirectory.path)
        if hadExistingInstallation {
            try fileManager.moveItem(at: installedDirectory, to: backupDirectory)
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: installedDirectory)
            if hadExistingInstallation {
                try? fileManager.removeItem(at: backupDirectory)
            }
        } catch {
            if hadExistingInstallation,
               !fileManager.fileExists(atPath: installedDirectory.path),
               fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: installedDirectory)
            }
            throw error
        }
    }

    private nonisolated static func installedFilesIfValid() -> SenseVoiceModelFiles? {
        guard let directory = try? modelDirectoryURL(),
              let manifestData = try? Data(
                contentsOf: directory.appendingPathComponent(manifestFileName)
              ),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.modelIdentifier == modelIdentifier else {
            return nil
        }

        for spec in specs {
            let fileURL = directory.appendingPathComponent(spec.fileName)
            guard let record = manifest.files[spec.fileName],
                  record.byteCount == spec.expectedSize,
                  record.sha256 == spec.sha256,
                  let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  Int64(values.fileSize ?? -1) == spec.expectedSize else {
                return nil
            }
        }

        return SenseVoiceModelFiles(
            model: directory.appendingPathComponent("model.int8.onnx"),
            tokens: directory.appendingPathComponent("tokens.txt"),
            vad: directory.appendingPathComponent("silero_vad.onnx")
        )
    }

    private nonisolated static func validate(
        fileURL: URL,
        against spec: DownloadSpec
    ) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == spec.expectedSize else {
            throw LocalSubtitleTranscriptionError.senseVoiceModelInvalid
        }
        guard try sha256(of: fileURL) == spec.sha256 else {
            throw LocalSubtitleTranscriptionError.senseVoiceModelInvalid
        }
    }

    private nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func modelsRootURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Teleprompter", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    private nonisolated static func modelDirectoryURL() throws -> URL {
        try modelsRootURL().appendingPathComponent(modelDirectoryName, isDirectory: true)
    }
}

private final class ModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (_ written: Int64, _ expected: Int64) -> Void

    private let progress: ProgressHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private var cancellationRequested = false

    init(progress: @escaping ProgressHandler) {
        self.progress = progress
    }

    func download(from remoteURL: URL, to destination: URL) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.destination = destination
                let session = URLSession(
                    configuration: .ephemeral,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.downloadTask(with: remoteURL)
                self.task = task
                let shouldCancel = cancellationRequested
                lock.unlock()
                shouldCancel ? task.cancel() : task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              200..<300 ~= response.statusCode else {
            finish(
                throwing: URLError(.badServerResponse)
            )
            return
        }
        guard let destination else {
            finish(throwing: URLError(.cannotCreateFile))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(throwing: nil)
        } catch {
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            finish(throwing: CancellationError())
        } else {
            finish(throwing: error)
        }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
