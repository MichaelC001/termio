import AVFoundation
import UIKit

/// Hold-to-talk voice dictation: record the mic while the user holds the
/// composer's mic button, then transcribe the clip with OpenAI's
/// `gpt-4o-transcribe` and hand the text back for the composer to drop into the
/// draft (never auto-sent — the same "dictation can't fire a half-formed
/// prompt" contract the composer already keeps).
///
/// The clip is short (a held button, seconds to a minute) and the text is
/// wanted only after release, so this records-then-POSTs to
/// `/v1/audio/transcriptions` rather than opening a realtime socket — see
/// `docs/rfcs/push-to-talk-voice-dictation.md` for why that model wins here.
final class VoiceDictation: NSObject {
    /// The transcription model. `gpt-4o-transcribe` is the most accurate of
    /// OpenAI's speech-to-text models — worth it for prompts dense with
    /// identifiers and paths — at $0.006/min.
    static let model = "gpt-4o-transcribe"

    enum Failure: Error {
        case missingKey
        case microphonePermissionDenied
        case recordingFailed
        case empty
        case network(String)
        case api(status: Int, message: String)

        /// A short line fit for the recording HUD's error state.
        var hudMessage: String {
            switch self {
            case .missingKey: "Add your OpenAI key in Settings ▸ Voice"
            case .microphonePermissionDenied: "Allow microphone access in Settings"
            case .recordingFailed: "Couldn't start recording"
            case .empty: "Didn't catch that — try again"
            case .network: "Network error — check your connection"
            case .api(_, let message): message
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    var isRecording: Bool { recorder?.isRecording ?? false }

    // MARK: - Recording

    /// Requests mic access if needed, then begins recording. `completion` fires
    /// on the main queue once recording is actually underway (or with the
    /// reason it couldn't start).
    func start(completion: @escaping (Result<Void, Failure>) -> Void) {
        guard Self.apiKey?.isEmpty == false else {
            completion(.failure(.missingKey))
            return
        }
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(.microphonePermissionDenied))
                return
            }
            do {
                try beginRecording()
                completion(.success(()))
            } catch {
                completion(.failure(.recordingFailed))
            }
        }
    }

    private func beginRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-dictation-\(UUID().uuidString).m4a")
        // AAC in an m4a container: one of OpenAI's accepted formats, and small.
        // 24 kHz mono is plenty for speech and keeps uploads tiny.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw Failure.recordingFailed }
        self.recorder = recorder
        self.fileURL = url
    }

    /// The current input level, 0…1, for the HUD's waveform. Call while
    /// recording; returns 0 otherwise.
    func currentLevel() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        // averagePower is roughly -160…0 dB; map the useful speech band to 0…1.
        let floor: Float = -50
        guard decibels > floor else { return 0 }
        return min(1, (decibels - floor) / -floor)
    }

    /// Discards the in-flight recording without transcribing (slide-to-cancel).
    func cancel() {
        recorder?.stop()
        cleanUp()
    }

    /// Stops recording and transcribes the clip. `completion` fires on the main
    /// queue with the transcript or the reason it failed.
    func stopAndTranscribe(completion: @escaping (Result<String, Failure>) -> Void) {
        guard let recorder, let fileURL else {
            completion(.failure(.recordingFailed))
            return
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        deactivateSession()

        // A stab at the button (or a bump) isn't a dictation; drop it quietly.
        guard duration >= 0.4 else {
            cleanUp()
            completion(.failure(.empty))
            return
        }

        guard let key = Self.apiKey, !key.isEmpty else {
            cleanUp()
            completion(.failure(.missingKey))
            return
        }
        transcribe(fileURL: fileURL, apiKey: key) { [weak self] result in
            self?.cleanUp()
            completion(result)
        }
    }

    private func cleanUp() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
        deactivateSession()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        let handler: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handler)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handler)
        }
    }

    // MARK: - Transcription

    private func transcribe(
        fileURL: URL, apiKey: String,
        completion: @escaping (Result<String, Failure>) -> Void
    ) {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            completion(.failure(.recordingFailed))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "termio-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        field("model", Self.model)
        // Plain-text response: the whole body is the transcript, no JSON to peel.
        field("response_format", "text")
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n"
        )
        body.appendString("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<String, Failure>
            defer { DispatchQueue.main.async { completion(result) } }

            if let error {
                result = .failure(.network(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(.network("No response"))
                return
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(.api(
                    status: http.statusCode, message: Self.apiErrorMessage(from: data) ?? "Transcription failed"
                ))
                return
            }
            let transcript = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            result = transcript.isEmpty ? .failure(.empty) : .success(transcript)
        }.resume()
    }

    /// OpenAI errors come back as `{ "error": { "message": ... } }`.
    private static func apiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message
    }

    // MARK: - API key (Keychain)

    private static let keychainService = "sh.termio.mobile.openai"
    private static let keychainAccount = "api-key"

    /// The OpenAI API key, stored in the Keychain (never UserDefaults). Setting
    /// nil or empty removes it.
    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, let data = value.data(using: .utf8)
            else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static var hasAPIKey: Bool { apiKey?.isEmpty == false }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

/// The recording overlay shown over the composer's pill while the mic button is
/// held: a pulsing red dot, an elapsed timer, a live waveform, and a hint that
/// swaps to a cancel warning when the finger slides up into the cancel zone —
/// Doubao's hold-to-talk affordances, pared to what a one-line composer can
/// carry. It also renders a brief "transcribing…" and error state.
final class VoiceRecordingHUD: UIView {
    private let dot = UIView()
    private let timeLabel = UILabel()
    private let hintLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let waveform = WaveformView()

    private var startDate: Date?
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        isHidden = true
        layer.cornerCurve = .continuous

        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timeLabel.textColor = .label
        timeLabel.text = "0:00"

        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .secondaryLabel
        hintLabel.text = "Slide up to cancel"

        spinner.hidesWhenStopped = true

        for subview in [dot, timeLabel, waveform, hintLabel, spinner] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            timeLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveform.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 10),
            waveform.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 22),
            waveform.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: waveform.trailingAnchor, constant: 10),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height, bounds.width) / 2
    }

    /// Shows the recording state and starts the timer. `levelProvider` is polled
    /// for the live waveform so the HUD never reaches into the recorder itself.
    func beginRecording(levelProvider: @escaping () -> Float) {
        isHidden = false
        spinner.stopAnimating()
        waveform.isHidden = false
        setCancelZone(false)
        backgroundColor = Self.material
        dot.isHidden = false
        timeLabel.isHidden = false
        waveform.reset()

        startDate = Date()
        pulseDot()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let startDate else { return }
            let elapsed = Int(Date().timeIntervalSince(startDate))
            timeLabel.text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            waveform.push(levelProvider())
        }
    }

    /// Toggles the cancel-zone warning (finger slid up past the threshold).
    func setCancelZone(_ active: Bool) {
        hintLabel.text = active ? "Release to cancel" : "Slide up to cancel"
        hintLabel.textColor = active ? .systemRed : .secondaryLabel
        dot.backgroundColor = active ? .systemGray : .systemRed
    }

    /// Swaps to the "transcribing…" state after release.
    func showTranscribing() {
        stopTimer()
        dot.isHidden = true
        timeLabel.isHidden = true
        waveform.isHidden = true
        hintLabel.text = "Transcribing…"
        hintLabel.textColor = .secondaryLabel
        spinner.startAnimating()
    }

    /// Flashes an error line, then hides the HUD.
    func showError(_ message: String) {
        stopTimer()
        isHidden = false
        spinner.stopAnimating()
        dot.isHidden = true
        timeLabel.isHidden = true
        waveform.isHidden = true
        backgroundColor = Self.material
        hintLabel.text = message
        hintLabel.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        stopTimer()
        spinner.stopAnimating()
        isHidden = true
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
    }

    private func pulseDot() {
        UIView.animate(
            withDuration: 0.6, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]
        ) {
            self.dot.alpha = 0.3
        }
    }

    private static var material: UIColor { .secondarySystemBackground }
}

/// A row of bars whose heights trail a rolling buffer of input levels — the
/// "I'm listening" waveform. Cheap: a handful of layers nudged each tick.
private final class WaveformView: UIView {
    private let barCount = 13
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 4
    private var bars: [CALayer] = []
    private var levels: [Float]

    override init(frame: CGRect) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = UIColor.systemRed.cgColor
            bar.cornerRadius = barWidth / 2
            layer.addSublayer(bar)
            bars.append(bar)
        }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(
            equalToConstant: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        ).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        layoutBars()
    }

    /// Shift the newest level in on the right and redraw.
    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, min(1, level)))
        layoutBars()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func layoutBars() {
        // No implicit animations — the timer already ticks fast enough to read
        // as motion, and animating each bar would smear the waveform.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        for (index, bar) in bars.enumerated() {
            let height = max(barWidth, CGFloat(levels[index]) * bounds.height)
            let x = CGFloat(index) * (barWidth + spacing)
            bar.frame = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}
