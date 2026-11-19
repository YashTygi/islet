import AVFoundation
import Speech
import SwiftUI

/// Hold-to-talk with Apple's on-device speech recognition. Hold Control + Shift: live text
/// while you speak final text when you let go. macOS 26+: SpeechAnalyzer (works with Siri and Dictation
/// off; the model downloads once). Older macOS: SFSpeechRecognizer, which needs Dictation turned on.
@MainActor @Observable
final class VoiceInput {
    enum Phase: Equatable { case preparing, listening, finishing, done, failed(String) }
    private(set) var phase: Phase = .done
    private(set) var text = ""
    private(set) var onDevice = false
    /// Recent loudness, 0…1, newest last: drives the wave in the collapsed notch.
    private(set) var levels: [Float] = Array(repeating: 0, count: 9)

    /// Each finished phrase while you're still talking (on macOS 26+), for live typing into a field.
    @ObservationIgnored var onPhrase: ((String) -> Void)?
    /// One engine per talk session, released when you let go. A long-lived engine whose mic input was ever set up
    /// keeps Bluetooth headphones in call mode (mono, 16 kHz: music and videos sound worse) until the app quits.
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var finishInput: (() async -> Void)?   // ends the audio and flushes the last words
    @ObservationIgnored private var cancel: (() -> Void)?

    var active: Bool { [.preparing, .listening, .finishing].contains(phase) }

    func start() {
        guard !active else { return }
        text = ""
        phase = .preparing
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                phase = .failed("Allow Microphone for Islet in System Settings → Privacy & Security → Microphone.")
                return
            }
            do {
                if #available(macOS 26, *) { try await beginAnalyzer() } else { try await beginLegacy() }
                if phase == .preparing { phase = .listening } else { await stopNow() }  // let go while preparing
            } catch {
                stopEngine()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stop listening; the last words arrive within a moment.
    func stop() {
        switch phase {
        case .preparing: phase = .finishing          // start() stops as soon as it's ready
        case .listening: phase = .finishing; Task { await stopNow() }
        default: break
        }
    }

    /// Waits until the last words are in (or 3 s).
    func stopAndWait() async {
        stop()
        for _ in 0..<60 where active { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func push(_ v: Float) {
        levels.removeFirst()
        levels.append(v)
    }

    /// RMS of a buffer as 0…1 on a speech-friendly scale (−50 dB … −10 dB).
    nonisolated static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let d = b.floatChannelData, b.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(b.frameLength) { sum += d[0][i] * d[0][i] }
        let db = 20 * log10(max(sqrtf(sum / Float(b.frameLength)), 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }

    static func selfTest() {
        let f = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func buf(_ amp: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 1600)!
            b.frameLength = 1600
            for i in 0..<1600 { b.floatChannelData![0][i] = amp * sinf(Float(i) * 0.3) }
            return b
        }
        precondition(level(buf(0)) == 0 && level(buf(1)) == 1)  // silence floor, loud clip
        let speech = level(buf(0.05))                           // ≈ −29 dB: normal talking
        precondition(speech > 0.4 && speech < 0.65, "\(speech)")
        VoiceCleanup.selfTest()
        VoiceGuess.selfTest()
        print("Voice self-test passed")
    }

    private var meter: @Sendable (Float) -> Void {
        { [weak self] v in Task { @MainActor in self?.push(v) } }
    }

    func clear() {
        cancel?()
        stopEngine()
        finishInput = nil
        cancel = nil
        text = ""
        levels = Array(repeating: 0, count: levels.count)
        phase = .done
    }

    private func stopNow() async {
        stopEngine()
        await finishInput?()
        finishInput = nil
        if phase == .finishing { phase = .done }
    }

    private func stopEngine() {
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        engine = nil
        levels = Array(repeating: 0, count: levels.count)
    }

    private static func fail(_ m: String) -> NSError { NSError(domain: "Islet", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    @available(macOS 26, *)
    private func beginAnalyzer() async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .alternativeTranscriptions], attributeOptions: [.transcriptionConfidence])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            text = "Downloading the speech model (once)…"
            try await install.downloadAndInstall()
            text = ""
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Self.fail("No audio format for speech") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let dict = VoiceCleanup.current
        if !dict.words.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = dict.words
            try? await analyzer.setContext(ctx)
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        onDevice = true

        let engine = AVAudioEngine()
        self.engine = engine
        Self.tapForAnalyzer(engine.inputNode, to: format, input: input, meter: meter)
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)

        // Final pieces accumulate; the volatile tail is replaced as you speak.
        let results = Task.detached { [weak self] in
            var final = ""
            for try await r in transcriber.results {
                let piece = VoiceCleanup.clean(VoiceGuess.apply(r.text, r.alternatives, dict), dict)
                if r.isFinal { final += piece }
                let shown = r.isFinal ? final : final + piece
                let final = r.isFinal
                await MainActor.run {
                    self?.text = shown.trimmingCharacters(in: .whitespaces)
                    if final, !piece.trimmingCharacters(in: .whitespaces).isEmpty { self?.onPhrase?(piece.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }
        finishInput = {
            input.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = await results.result
        }
        cancel = { input.finish(); results.cancel(); Task { await analyzer.cancelAndFinishNow() } }
    }

    // Audio and recognizer callbacks run on background threads, so their closures are built outside the
    // main actor (Swift 6 would otherwise trap when they fire off the main thread).

    @available(macOS 26, *)
    nonisolated private static func tapForAnalyzer(_ mic: AVAudioInputNode, to format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation,
                                                   meter: @escaping @Sendable (Float) -> Void) {
        let micFormat = mic.outputFormat(forBus: 0)
        nonisolated(unsafe) let converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)
        mic.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in
            meter(level(buffer))
            guard let converter else { input.yield(AnalyzerInput(buffer: buffer)); return }
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / micFormat.sampleRate + 1)
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            nonisolated(unsafe) var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if err == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        }
    }

    nonisolated private static func tapForLegacy(_ mic: AVAudioInputNode, _ req: SFSpeechAudioBufferRecognitionRequest,
                                                 meter: @escaping @Sendable (Float) -> Void) {
        mic.installTap(onBus: 0, bufferSize: 1024, format: mic.outputFormat(forBus: 0)) { buffer, _ in meter(level(buffer)); req.append(buffer) }
    }

    nonisolated private static func recognize(_ r: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                              done: AsyncStream<Void>.Continuation,
                                              text: @escaping @MainActor (String) -> Void) -> SFSpeechRecognitionTask {
        r.recognitionTask(with: req) { result, error in
            if let t = result?.bestTranscription.formattedString { Task { @MainActor in text(t) } }
            if result?.isFinal == true || error != nil { done.finish() }
        }
    }

    private func beginLegacy() async throws {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { throw Self.fail("Allow Speech Recognition for Islet in System Settings → Privacy & Security.") }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw Self.fail("Speech recognition isn't available for your language.") }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        onDevice = recognizer.supportsOnDeviceRecognition
        req.requiresOnDeviceRecognition = onDevice
        req.addsPunctuation = true
        let dict = VoiceCleanup.current
        req.contextualStrings = dict.words
        let engine = AVAudioEngine()
        self.engine = engine
        Self.tapForLegacy(engine.inputNode, req, meter: meter)
        engine.prepare()
        try engine.start()
        let done = AsyncStream<Void>.makeStream()
        let task = Self.recognize(recognizer, req, done: done.continuation) { [weak self] t in self?.text = VoiceCleanup.clean(t, dict) }
        finishInput = {
            req.endAudio()
            for await _ in done.stream {}
        }
        cancel = { task.cancel() }
    }
}

/// Fixes applied to every recognized phrase before it's shown or typed: your word list first, then
/// filler sounds and doubled words. Plain text rules, so it's instant and costs no memory.
enum VoiceCleanup {
    static let defaultsKey = "voiceDictionary"
    /// Learned corrections, "heard>meant": count. Written by CorrectionLearner, shown in Settings.
    static let learnedKey = "voiceLearned"
    /// One entry per line. "Name" = a word to expect. "heard, heard = Name" = also replace what it mishears.
    static let starter = "whisker flow, whiskey flow, whisper flow = Wispr Flow\nIslet"

    struct Dictionary: Sendable {
        var words: [String] = []                           // hints for the recognizer
        var fixes: [(heard: String, meant: String)] = []   // replacements, applied in order
        var vocabulary: [String: String] = [:]             // lowercased word → your spelling, for VoiceGuess
        var learned: [String: Int] = [:]                   // "heard>meant" → times you made that fix
    }

    static func parse(_ text: String) -> Dictionary {
        var d = Dictionary()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let meant = parts.last, !meant.isEmpty else { continue }
            d.words.append(meant)
            for w in meant.split(separator: " ") where w.count > 1 { d.vocabulary[w.lowercased()] = String(w) }
            guard parts.count == 2 else { continue }
            for heard in parts[0].split(separator: ",") {
                let h = heard.trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { d.fixes.append((h, meant)) }
            }
        }
        return d
    }

    static var current: Dictionary {
        let u = UserDefaults.standard
        var d = parse(u.string(forKey: defaultsKey) ?? starter)
        d.learned = u.dictionary(forKey: learnedKey) as? [String: Int] ?? [:]
        d.words += Set(d.learned.keys.compactMap { $0.split(separator: ">").last.map(String.init) })
        return d
    }

    static func clean(_ raw: String, _ d: Dictionary) -> String {
        let lead = raw.prefix { $0.isWhitespace }   // pieces join on their own leading space: keep it
        var t = String(raw.dropFirst(lead.count))
        let wasCapital = t.first?.isUppercase == true
        func re(_ pattern: String, _ with: String) {
            t = t.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        for f in d.fixes {
            re("\\b\(NSRegularExpression.escapedPattern(for: f.heard))\\b", NSRegularExpression.escapedTemplate(for: f.meant))
        }
        re("\\b(?:u+m+|u+h+|e+r+m+|h+m+)\\b(?!-)[,.]?\\s*", "")                // um, uh, erm, hmm (not "uh-oh")
        // ponytail: only back-to-back repeats; "that that" and "had had" are often meant, so they stay.
        re("\\b(?!(?:that|had)\\b)(\\w+)(?:\\s+\\1\\b)+", "$1")
        re("\\s+([,.!?;:])", "$1")
        re(" {2,}", " ")
        t = t.trimmingCharacters(in: .whitespaces)
        if wasCapital, let c = t.first, c.isLowercase { t = c.uppercased() + t.dropFirst() }
        return t.isEmpty ? "" : lead + t
    }

    static func selfTest() {
        let d = parse(starter + "\n\nsink = sync")
        precondition(d.words == ["Wispr Flow", "Islet", "sync"] && d.fixes.count == 4)
        func ok(_ a: String, _ b: String) { precondition(clean(a, d) == b, "\(a) -> \(clean(a, d))") }
        ok("We tried the whisker flow kind of thing.", "We tried the Wispr Flow kind of thing.")
        ok("Um, so I I think, uh, it works.", "So I think, it works.")
        ok(" the the notes sink now", " the notes sync now")
        ok("I said that that was fine, uh-oh.", "I said that that was fine, uh-oh.")
        ok("Hmm.", "")
        ok("Whiskers stay.", "Whiskers stay.")
    }
}

/// Picks a different word only on the recognizer's own evidence: it was unsure of the word (confidence < 0.9)
/// AND one of its own alternative guesses for that spot is in your word list or is a fix you've made before.
/// Otherwise the text is left alone; it never invents a word the recognizer didn't consider.
enum VoiceGuess {
    static let unsure = 0.9

    /// The replacement for `heard`, or nil to keep it. `guesses` are lowercased.
    static func choose(_ heard: String, confidence: Double?, guesses: Set<String>, _ d: VoiceCleanup.Dictionary) -> String? {
        guard let c = confidence, c < unsure, !guesses.isEmpty else { return nil }
        let h = heard.lowercased()
        if let g = guesses.filter({ d.learned["\(h)>\($0)", default: 0] > 0 }).max(by: { d.learned["\(h)>\($0)"]! < d.learned["\(h)>\($1)"]! }) {
            return g
        }
        return guesses.sorted().lazy.compactMap { d.vocabulary[$0] }.first
    }

    static func core(_ s: String) -> Range<String.Index>? { s.range(of: "[\\p{L}\\p{N}']+", options: .regularExpression) }
    static func words(_ s: String) -> [String] {
        s.lowercased().matches(of: /[\p{L}\p{N}']+/).map { String($0.output) }
    }

    /// `run` with its word swapped for `word`, keeping spacing, punctuation and a leading capital.
    static func swap(_ run: String, to word: String) -> String {
        guard let r = core(run) else { return run }
        var w = word
        if run[r].first?.isUppercase == true, let f = w.first { w = f.uppercased() + w.dropFirst() }
        return run.replacingCharacters(in: r, with: w)
    }

    @available(macOS 26, *)
    static func apply(_ text: AttributedString, _ alternatives: [AttributedString], _ d: VoiceCleanup.Dictionary) -> String {
        let runs = text.runs.map { (String(text[$0.range].characters), $0.transcriptionConfidence) }
        let top = runs.map { words($0.0) }
        // ponytail: only alternatives with the same word count give per-word guesses (almost all of them do);
        // aligning different lengths would need a word diff.
        var guesses = Array(repeating: Set<String>(), count: runs.count)
        let flat = top.flatMap { $0 }
        for alt in alternatives {
            let a = words(String(alt.characters))
            guard a.count == flat.count else { continue }
            var k = 0
            for (i, ws) in top.enumerated() {
                if ws.count == 1, a[k] != ws[0] { guesses[i].insert(a[k]) }
                k += ws.count
            }
        }
        return runs.indices.map { i in
            guard top[i].count == 1, let pick = choose(top[i][0], confidence: runs[i].1, guesses: guesses[i], d) else { return runs[i].0 }
            return swap(runs[i].0, to: pick)
        }.joined()
    }

    static func selfTest() {
        var d = VoiceCleanup.parse("cache\nIslet")
        precondition(choose("cash", confidence: 0.6, guesses: ["cache", "catch"], d) == "cache")   // unsure + known guess
        precondition(choose("cash", confidence: 0.95, guesses: ["cache"], d) == nil)               // sure of itself
        precondition(choose("cash", confidence: 0.6, guesses: ["catch"], d) == nil)                // guess not known
        precondition(choose("cash", confidence: nil, guesses: ["cache"], d) == nil)
        precondition(choose("island", confidence: 0.5, guesses: ["islet"], d) == "Islet")          // your spelling
        d.learned = ["dusting>testing": 2]
        precondition(choose("Dusting", confidence: 0.5, guesses: ["testing", "trusting"], d) == "testing")
        precondition(choose("dusting", confidence: 0.5, guesses: ["trusting"], d) == nil)          // learned word not guessed
        precondition(swap(" dusting,", to: "testing") == " testing," && swap("Dusting", to: "testing") == "Testing")
    }
}

/// Wispr-style wave for the collapsed notch: one bar per recent loudness reading, scrolling.
struct VoiceWave: View {
    let voice: VoiceInput

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(voice.levels.enumerated()), id: \.offset) { i, v in
                // Middle bars a bit taller, a floor so the wave never flattens to nothing.
                let shape: Float = 1 - abs(Float(i) - 4) * 0.08
                Capsule().fill(.white)
                    .frame(width: 2.5, height: CGFloat(4 + 14 * max(v, 0.05) * shape))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.09), value: voice.levels)
    }
}
