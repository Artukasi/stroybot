import AVFoundation
import Speech
import SwiftUI

/// Диктовка по-русски: говорите — текст появляется сразу. Если телефон умеет, распознаёт без интернета
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var running = false
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))

    func toggle() {
        if running { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !running else { return }
        problem = nil
        text = ""
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else {
            problem = "Разрешите распознавание речи: Настройки → СтройСкан."
            return
        }
        let mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
        guard mic else {
            problem = "Разрешите микрофон: Настройки → СтройСкан."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Распознавание речи сейчас недоступно. Проверьте интернет."
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            problem = "Микрофон занят другим приложением."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        guard Dictation.tap(engine.inputNode, req) else {
            problem = "Микрофон не отвечает."
            return
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            problem = "Не получилось включить микрофон."
            return
        }
        request = req
        running = true
        task = Dictation.listen(recognizer, req) { [weak self] said, done in
            guard let self else { return }
            if let said { self.text = said }
            if done { self.stop() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func tap(_ input: AVAudioInputNode, _ req: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        return true
    }

    nonisolated private static func listen(_ recognizer: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                           _ update: @escaping @MainActor (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: req) { result, error in
            let said = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in update(said, done) }
        }
    }
}

/// Кнопка «Надиктовать»: пока горит красным — слушает
struct DictateButton: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        Button { dictation.toggle() } label: {
            Label(dictation.running ? "Стоп — готово" : "Надиктовать голосом",
                  systemImage: dictation.running ? "stop.circle.fill" : "mic.fill")
                .font(.subheadline.bold())
                .foregroundStyle(dictation.running ? Color.red : Palette.draft)
                .symbolEffectPulse(dictation.running)
        }
        if let p = dictation.problem { Text(p).font(.caption).foregroundStyle(.red) }
    }
}

private extension View {
    @ViewBuilder func symbolEffectPulse(_ on: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.pulse, isActive: on)
        } else {
            self.opacity(on ? 0.8 : 1)
        }
    }
}
