import AVFoundation
import CoreMedia
import Foundation

/// The single microphone capture behind a conversation session.
///
/// Both conversation lanes read from this one tap. Giving each lane its own capture
/// would mean two `AVCaptureSession`s contending for the built-in microphone and, on
/// iOS, two activations of the one process-wide `AVAudioSession` — where whichever
/// session deactivates first tears the other one's input down with it.
///
/// Buffers are converted once, here, into the format both analyzers accepted, so the
/// two lanes compare confidences over identical samples.
final class ConversationAudioTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum TapError: LocalizedError, AppLocalizableError {
        case microphonePermissionDenied
        case missingMicrophone
        case captureUnavailable(String)

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .microphonePermissionDenied:
                return AppLocalization.string(.microphonePermissionDenied, languageID: languageID)
            case .missingMicrophone:
                return AppLocalization.string(.missingMicrophoneDevice, languageID: languageID)
            case .captureUnavailable(let reason):
                return AppLocalization.string(.failedToStartCaptureFormat, languageID: languageID, reason)
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    /// Format offered to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)`
    /// as the preferred capture shape: 16 kHz mono Float32, what the speech stack wants.
    static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    /// Called on the capture queue with a buffer already in `outputFormat`.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let outputFormat: AVAudioFormat
    private let captureQueue = DispatchQueue(
        label: "org.audreyt.v2s.conversation.capture",
        qos: .userInitiated
    )
    private var session: AVCaptureSession?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        super.init()
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                do {
                    try startOnCaptureQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnCaptureQueue() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw TapError.missingMicrophone
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw TapError.captureUnavailable(device.localizedName)
        }

#if os(iOS)
        // Manual session management, matching LiveTranscriptionSession: the shared
        // category (with its Bluetooth option) and any preferred input the user
        // picked must survive this capture session starting.
        session.automaticallyConfiguresApplicationAudioSession = false
#endif

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

#if os(iOS)
        try IOSAudioSessionConfigurator.applyRecordCategory()
        try AVAudioSession.sharedInstance().setActive(true)
#endif

        self.session = session
        session.startRunning()
    }

    /// Stops capture and tears down every queue-owned field in arrival order behind
    /// the last sample callback. `stop()` is called from the main actor, never from
    /// `captureQueue`, so the synchronous barrier cannot self-deadlock.
    func stop() {
        captureQueue.sync {
            self.session?.stopRunning()
            self.session = nil
            self.onBuffer = nil
            self.converter = nil
            self.converterInputFormat = nil

#if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
#endif
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let onBuffer,
              let captured = Self.pcmBuffer(from: sampleBuffer),
              let converted = convert(captured) else {
            return
        }
        onBuffer(converted)
    }

    // MARK: - Private

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format != outputFormat else {
            return buffer
        }

        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInputFormat = buffer.format
        }

        guard let converter else {
            return nil
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
