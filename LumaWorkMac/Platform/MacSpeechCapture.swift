import Accelerate
import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class MacSpeechCapture {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case finalizing
    }

    private(set) var phase: Phase = .idle
    private(set) var audioLevel: CGFloat = 0
    private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptHandler: ((String) -> Void)?
    private var initialText = ""
    private var currentTranscript = ""
    private var hasInstalledTap = false
    private var acceptsRecognitionResults = false
    private var operationID: UUID?
    private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    init() {
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.isActive else { return }; self.reset(); self.errorMessage = "Аудиоустройство изменилось. Запустите диктовку снова." }
        }
    }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) } }

    var isActive: Bool {
        phase != .idle
    }

    func start(initialText: String, onTranscript: @escaping (String) -> Void) async {
        guard phase == .idle else { return }

        phase = .preparing
        errorMessage = nil
        let operationID = UUID()
        self.operationID = operationID
        self.initialText = initialText
        currentTranscript = ""
        transcriptHandler = onTranscript

        do {
            try await requestPermissions()
            guard self.operationID == operationID, phase == .preparing else { return }
            try beginRecognition()
        } catch let error as AssistantSpeechRecognitionError {
            guard self.operationID == operationID else { return }
            stopImmediately(restoreInitialText: false)
            errorMessage = error.message
        } catch {
            guard self.operationID == operationID else { return }
            stopImmediately(restoreInitialText: false)
            errorMessage = "Не удалось запустить локальную диктовку."
        }
    }

    func finish() {
        guard phase == .recording else { return }
        stopAudioCapture()
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        phase = .finalizing
        audioLevel = 0
        finalizationTask?.cancel()
        finalizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.phase == .finalizing else { return }
            self?.completeRecognition()
        }
    }

    func cancel() {
        stopImmediately(restoreInitialText: true)
    }

    func finishForSubmission() {
        stopImmediately(restoreInitialText: false)
    }

    func reset() {
        stopImmediately(restoreInitialText: false)
        errorMessage = nil
    }

    private func requestPermissions() async throws {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        case let current:
            speechStatus = current
        }

        guard speechStatus == .authorized else {
            throw AssistantSpeechRecognitionError.speechPermissionDenied
        }

        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else {
            throw AssistantSpeechRecognitionError.microphonePermissionDenied
        }
    }

    private func beginRecognition() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")),
              recognizer.supportsOnDeviceRecognition else {
            throw AssistantSpeechRecognitionError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AssistantSpeechRecognitionError.microphoneUnavailable
        }

        speechRecognizer = recognizer
        recognitionRequest = request
        acceptsRecognitionResults = true
        let operation = operationID
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard self?.operationID == operation else { return }
                self?.handleRecognition(result: result, error: error)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            let level = MacSpeechCapture.normalizedAudioLevel(buffer)
            Task { @MainActor [weak self] in
                guard self?.operationID == operation, self?.phase == .recording else { return }
                self?.audioLevel = level
            }
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()
        phase = .recording
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        guard acceptsRecognitionResults else { return }

        if let result {
            currentTranscript = result.bestTranscription.formattedString
            transcriptHandler?(combinedText(with: currentTranscript))
            if result.isFinal {
                completeRecognition()
                return
            }
        }

        if error != nil {
            if currentTranscript.isEmpty {
                errorMessage = "Не удалось распознать речь. Попробуйте ещё раз."
            }
            completeRecognition()
        }
    }

    private func completeRecognition() {
        finalizationTask?.cancel()
        finalizationTask = nil
        operationID = nil
        stopAudioCapture()
        acceptsRecognitionResults = false
        let task = recognitionTask
        recognitionTask = nil
        recognitionRequest = nil
        transcriptHandler = nil
        phase = .idle
        audioLevel = 0
        task?.cancel()
    }

    private func stopImmediately(restoreInitialText: Bool) {
        finalizationTask?.cancel()
        finalizationTask = nil
        operationID = nil
        acceptsRecognitionResults = false
        stopAudioCapture()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        if restoreInitialText {
            transcriptHandler?(initialText)
        }
        transcriptHandler = nil
        currentTranscript = ""
        phase = .idle
        audioLevel = 0
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
    }

    private func combinedText(with transcript: String) -> String {
        guard !initialText.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return initialText }
        let separator = initialText.last?.isWhitespace == true ? "" : " "
        return initialText + separator + transcript
    }

    nonisolated private static func normalizedAudioLevel(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rootMeanSquare: Float = 0
        vDSP_rmsqv(samples, 1, &rootMeanSquare, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_01))
        return CGFloat(min(1, max(0, (decibels + 55) / 45)))
    }
}

private enum AssistantSpeechRecognitionError: Error {
    case speechPermissionDenied
    case microphonePermissionDenied
    case onDeviceRecognitionUnavailable
    case microphoneUnavailable

    var message: String {
        switch self {
        case .speechPermissionDenied:
            "Разрешите распознавание речи в настройках macOS."
        case .microphonePermissionDenied:
            "Разрешите доступ к микрофону в настройках macOS."
        case .onDeviceRecognitionUnavailable:
            "Локальная диктовка недоступна на этом устройстве."
        case .microphoneUnavailable:
            "Микрофон сейчас недоступен."
        }
    }
}
