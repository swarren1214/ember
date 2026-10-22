import CryptoKit
import Foundation
import KokoroSwift
import MLX
import Observation
import UIKit

// Ember's natural voice: the Kokoro neural voice model running on the iPhone (MLX on the GPU,
// or the CPU while the app is in the background, where iOS doesn't allow GPU work). Speech is
// generated on the device; nothing about the conversation is sent anywhere.
//
// The model (~330 MB, Apache 2.0) is downloaded once, from Hugging Face, when the person turns
// on the natural voice; the voice styles (~14 MB) ship in the app as Resources/Kokoro/kokoro-voices.bin.
//
// Copied from Sated's Services/Voice/KokoroVoice.swift (itself from Hearken's), unchanged except
// for names and messages. The model is shared with Sated and Hearken through the App Group
// `group.com.stephenwarren.voice`, so it's downloaded once per iPhone. Ember speaks `af_heart`,
// the one voice Paradee has, so it sounds the same on iPhone and Apple Watch.

// MARK: - Voices

nonisolated enum KokoroVoices {
    struct Voice: Identifiable, Hashable {
        /// Kokoro's name, e.g. "af_heart".
        let id: String
        let name: String
        let detail: String
        /// Position in kokoro-voices.bin.
        let slot: Int

        var isMale: Bool { id.dropFirst().first == "m" }
        var isBritish: Bool { id.hasPrefix("b") }
    }

    /// In the order they're packed in kokoro-voices.bin (510 × 1 × 256 float32 each).
    private static let packed = [
        "af_heart", "af_bella", "af_nicole", "af_aoede", "af_kore", "af_sarah", "af_nova", "af_sky",
        "af_alloy", "af_jessica", "af_river", "am_michael", "am_fenrir", "am_puck", "am_echo", "am_eric",
        "am_liam", "am_onyx", "am_santa", "am_adam", "bf_emma", "bf_isabella", "bf_alice", "bf_lily",
        "bm_george", "bm_fable", "bm_lewis", "bm_daniel",
    ]

    /// The default: warm and clear.
    static let defaultID = "af_heart"
    /// Shown in What Ember Knows › Voice.
    static var choices: [Voice] { featured.compactMap(voice) }

    static let all: [Voice] = packed.enumerated().compactMap { slot, id in
        guard id != "am_santa" else { return nil }
        let accent = id.hasPrefix("b") ? "British" : "American"
        let gender = id.dropFirst().first == "m" ? "male" : "female"
        let name = id.split(separator: "_").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? id
        return Voice(id: id, name: name, detail: "\(accent) English, \(gender)", slot: slot)
    }

    static func voice(_ id: String) -> Voice? { all.first { $0.id == id } }

    /// Featured first in Settings; the rest follow.
    static let featured = ["af_heart", "af_bella", "am_michael", "am_adam", "bf_emma", "bm_george", "bm_lewis"]

    /// The voice picked when someone switches gender or accent.
    static func recommended(male: Bool, british: Bool) -> String {
        switch (male, british) {
        case (false, false): "af_heart"
        case (true, false): "am_michael"
        case (false, true): "bf_emma"
        case (true, true): "bm_george"
        }
    }
}

// MARK: - Model download

/// The Kokoro model on this device: whether it's here, downloading, or can't run.
@MainActor
@Observable
final class KokoroModel: NSObject {
    static let shared = KokoroModel()

    enum State: Equatable {
        /// The Simulator (MLX needs a real device's GPU).
        case unavailable
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded

    /// Where to get the Kokoro v1.0 weights for MLX: Hugging Face first, then the copy in
    /// KokoroSwift's sample app on GitHub. Either is accepted only if it's byte-for-byte the
    /// file KokoroSwift is tested with (checked by SHA-256 below).
    static let remoteURLs = [
        URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors")!,
        URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/kokoro-v1_0.safetensors")!,
    ]
    /// SHA-256 of the tested kokoro-v1_0.safetensors (327,115,152 bytes).
    nonisolated static let expectedSHA256 = "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
    nonisolated static let downloadFailedMessage = "Ember’s voice couldn’t download. Try again in a moment."
    /// Roughly 330 MB; shown before downloading.
    static let approximateSize = "330 MB"

    /// The App Group every one of Steve Warren's apps that speaks with Kokoro belongs to. The
    /// model lives in the group's shared folder, so it's downloaded once per iPhone and every
    /// app uses the same file. (Memory isn't shared: each app loads it while it speaks.)
    nonisolated static let sharedGroupID = "group.com.stephenwarren.voice"

    /// The shared folder, or this app's own folder if the App Group isn't set up.
    nonisolated static var folder: URL {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroupID) {
            return shared.appending(path: "Library/Application Support/Kokoro", directoryHint: .isDirectory)
        }
        return privateFolder
    }

    nonisolated private static var privateFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Kokoro", directoryHint: .isDirectory)
    }

    nonisolated static var localURL: URL {
        folder.appending(path: "kokoro-v1_0.safetensors")
    }

    /// Before the shared folder, the model lived in each app's own storage. Move it over (or
    /// drop it, if another app already put one there), so nothing is downloaded twice.
    nonisolated private static func moveIntoSharedFolderIfNeeded() {
        let manager = FileManager.default
        let old = privateFolder.appending(path: "kokoro-v1_0.safetensors")
        let new = localURL
        guard old != new, manager.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        if manager.fileExists(atPath: new.path(percentEncoded: false)) {
            try? manager.removeItem(at: old)
            return
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var shared = folder
            try? shared.setResourceValues(values)
            try manager.moveItem(at: old, to: new)
        } catch {
            // Leave it where it is; the app downloads again only if the shared copy is missing.
        }
    }

    /// Another app may have downloaded (or removed) the model since this one last looked.
    func refresh() {
        #if !targetEnvironment(simulator)
        let exists = FileManager.default.fileExists(atPath: Self.localURL.path(percentEncoded: false))
        switch state {
        case .notDownloaded where exists: state = .ready
        case .ready where !exists: state = .notDownloaded
        default: break
        }
        #endif
    }

    nonisolated private enum Keys {
        /// Set while the model loads; still set at launch means loading crashed last time.
        static let loading = "kokoro.loading"
        static let broken = "kokoro.broken"
    }

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var sourceIndex = 0
    /// The last whole percent reported. URLSession reports every few KB (thousands of times for
    /// this file); passing each one to the main thread re-rendered the progress bar faster than
    /// it could draw, so the backlog froze the app for a while after the download finished.
    /// Only touched on the session's serial delegate queue (and reset before a task starts).
    @ObservationIgnored nonisolated(unsafe) private var lastReportedPercent = -1

    override init() {
        super.init()
        #if targetEnvironment(simulator)
        state = .unavailable
        #else
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Keys.loading) {
            // The app quit while loading the model last time: don't try again automatically.
            defaults.set(false, forKey: Keys.loading)
            defaults.set(true, forKey: Keys.broken)
        }
        Self.moveIntoSharedFolderIfNeeded()
        if defaults.bool(forKey: Keys.broken) {
            state = .failed("The natural voice couldn't load on this device.")
        } else if FileManager.default.fileExists(atPath: Self.localURL.path(percentEncoded: false)) {
            state = .ready
        }
        // Coming back to the app: pick up a download another app finished meanwhile.
        NotificationCenter.default.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KokoroModel.shared.refresh() }
        }
        #endif
    }

    var isReady: Bool { state == .ready }

    /// Starts the download. `wifiOnly` keeps it off cellular (used when it starts on its own).
    func download(wifiOnly: Bool = false) {
        // Another of the apps may already have it.
        refresh()
        switch state {
        case .notDownloaded, .failed: break
        default: return
        }
        UserDefaults.standard.set(false, forKey: Keys.broken)
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = !wifiOnly
        configuration.allowsConstrainedNetworkAccess = !wifiOnly
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        sourceIndex = 0
        state = .downloading(0)
        startTask()
    }

    private func startTask() {
        guard let session, Self.remoteURLs.indices.contains(sourceIndex) else { return }
        let task = session.downloadTask(with: Self.remoteURLs[sourceIndex])
        lastReportedPercent = -1
        self.task = task
        task.resume()
    }

    /// This source failed or sent a different file: try the next one, if there is one.
    fileprivate func tryNextSource(or error: String) {
        if sourceIndex + 1 < Self.remoteURLs.count {
            sourceIndex += 1
            state = .downloading(0)
            startTask()
        } else {
            finished(error: error)
        }
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .notDownloaded
    }

    /// Frees the space; Ember falls back to the system voice. The model is shared, so this
    /// removes it for the other apps too.
    func remove() {
        cancelDownload()
        KokoroSynth.shared.unload()
        try? FileManager.default.removeItem(at: Self.localURL)
        UserDefaults.standard.set(false, forKey: Keys.broken)
        state = .notDownloaded
    }

    nonisolated static func markLoading(_ loading: Bool) {
        UserDefaults.standard.set(loading, forKey: Keys.loading)
    }

    fileprivate func finished(error: String?) {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        if let error {
            state = .failed(error)
        } else {
            state = .ready
        }
    }

    fileprivate func progressed(_ fraction: Double) {
        if case .downloading = state { state = .downloading(fraction) }
    }
}

extension KokoroModel: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percent = Int(fraction * 100)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        Task { @MainActor in KokoroModel.shared.progressed(fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so check and move it now.
        var error: String?
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        if status != 200 || KokoroModel.sha256(of: location) != KokoroModel.expectedSHA256 {
            Task { @MainActor in KokoroModel.shared.tryNextSource(or: "The download didn't finish correctly. Try again.") }
            return
        } else {
            do {
                let destination = KokoroModel.localURL
                var folder = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Re-downloadable, so keep it out of iCloud backups.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? folder.setResourceValues(values)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch _ {
                error = KokoroModel.downloadFailedMessage
            }
        }
        let result = error
        Task { @MainActor in KokoroModel.shared.finished(error: result) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        let message = (error as? URLError)?.code == .notConnectedToInternet ? "You’re offline. Connect to download Ember’s voice." : KokoroModel.downloadFailedMessage
        Task { @MainActor in KokoroModel.shared.tryNextSource(or: message) }
    }

    /// Hashes the file in 4 MB pieces, so it never needs the whole model in memory.
    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Synthesis

/// How a natural voice delivers the text.
nonisolated struct VoiceTuning: Hashable, Sendable {
    /// Kokoro's own speaking pace: 1 is natural, lower is slower and more deliberate. Unlike
    /// playback speed, the voice itself paces the words, so it stays natural.
    var pace: Double = 1
    /// How far the voice's intonation moves from an average reading: 1 is the voice as
    /// recorded, lower is calmer and flatter, higher is more animated.
    var expressiveness: Double = 1

    static let paces: [Double] = [0.85, 0.92, 1, 1.08, 1.16]
    static let expressions: [Double] = [0.6, 0.8, 1, 1.2, 1.4]
}

/// Runs Kokoro on its own queue. Loads the model on first use (a few seconds).
nonisolated final class KokoroSynth: @unchecked Sendable {
    static let shared = KokoroSynth()
    static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    private let queue = DispatchQueue(label: "com.stephenwarren.ember.kokoro", qos: .userInitiated)
    private var tts: KokoroTTS?
    private var styles: [String: MLXArray] = [:]
    private var voiceData: Data?
    /// The average prosody half of every voice style, the center expressiveness scales around.
    private var averageProsody: [Float]?

    private static let rows = 510
    private static let width = 256
    /// Kokoro reads the second half of each style row for duration and intonation, the first
    /// half for the sound of the voice. Expressiveness only changes the second half.
    private static let prosodyStart = 128

    /// How much freed GPU memory MLX may keep around for reuse. Left unlimited, MLX keeps every
    /// buffer it has ever used, and generating verse after verse grows the app's memory until
    /// iOS kills it, which shows up as a crash a moment after speech starts.
    private static let gpuCacheLimit = 32 * 1024 * 1024

    /// Unloads the model after this long without speech, freeing several hundred MB.
    private static let idleUnloadDelay: TimeInterval = 120
    private var idleUnload: DispatchWorkItem?

    private init() {
        // Start watching the app's state now, before any GPU work.
        _ = GPUGate.shared
        // Give the memory back when iOS asks for it; the next verse reloads the model.
        NotificationCenter.default.addObserver(
            // UIApplication.didReceiveMemoryWarningNotification, by name: this class isn't on the main actor.
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.unload() }
    }

    /// Loads the model ahead of time, so the first reply starts quickly.
    func prewarm() {
        queue.async { [self] in
            _ = try? loadIfNeeded()
            scheduleIdleUnload()
        }
    }

    func unload() {
        queue.async { [self] in
            idleUnload?.cancel()
            idleUnload = nil
            tts = nil
            styles = [:]
            MLX.GPU.clearCache()
        }
    }

    /// On `queue`: restarts the countdown to unloading the model.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.tts = nil
            self?.styles = [:]
            MLX.GPU.clearCache()
        }
        idleUnload = item
        queue.asyncAfter(deadline: .now() + Self.idleUnloadDelay, execute: item)
    }

    /// Speech for `text` as 24 kHz mono samples. `gpu` is false while the app is in the background.
    /// Cancelling the calling task (skipping ahead, stopping) drops the request before it
    /// starts, or between sentences, so stale verses don't hold up the one wanted next.
    func synthesize(_ text: String, voice: String, tuning: VoiceTuning = VoiceTuning(), gpu: Bool) async throws -> [Float] {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { scheduleIdleUnload() }
                    do {
                        try cancelled.check()
                        let tts = try loadIfNeeded()
                        let style = try style(for: voice, expressiveness: tuning.expressiveness)
                        let language: Language = voice.hasPrefix("b") ? .enGB : .enUS
                        var samples: [Float] = []
                        for chunk in KokoroText.chunks(text) {
                            try cancelled.check()
                            samples += try speak(chunk, tts: tts, style: style, language: language, pace: Float(tuning.pace), gpu: gpu)
                        }
                        // Hand back what this verse used beyond the small reuse cache.
                        MLX.GPU.clearCache()
                        continuation.resume(returning: samples)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// One chunk; splits it further if Kokoro says it's too long.
    private func speak(_ chunk: String, tts: KokoroTTS, style: MLXArray, language: Language, pace: Float, gpu: Bool) throws -> [Float] {
        do {
            let run = { try tts.generateAudio(voice: style, language: language, text: chunk, speed: pace).0 }
            // The GPU only while the app is active: iOS ends an app that sends GPU work from
            // the background (the crash a moment after locking the screen). The gate is
            // checked per chunk, so a verse that started on the GPU finishes on the CPU.
            if gpu, let samples = try GPUGate.shared.run(run) { return samples }
            return try Device.withDefaultDevice(.cpu, run)
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            let halves = KokoroText.halves(chunk)
            guard halves.count == 2 else { throw KokoroTTS.KokoroTTSError.tooManyTokens }
            return try speak(halves[0], tts: tts, style: style, language: language, pace: pace, gpu: gpu)
                + speak(halves[1], tts: tts, style: style, language: language, pace: pace, gpu: gpu)
        }
    }

    private func loadIfNeeded() throws -> KokoroTTS {
        if let tts { return tts }
        let url = KokoroModel.localURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw CocoaError(.fileNoSuchFile) }
        MLX.GPU.set(cacheLimit: Self.gpuCacheLimit)
        // If loading crashes the app, the flag is still set next launch and natural voices turn off.
        KokoroModel.markLoading(true)
        // Reloading after a memory warning can happen with the screen locked: keep it off the GPU then.
        let make = { KokoroTTS(modelPath: url, g2p: .misaki) }
        let loaded = GPUGate.shared.run(make) ?? Device.withDefaultDevice(.cpu, make)
        KokoroModel.markLoading(false)
        tts = loaded
        return loaded
    }

    private func style(for id: String, expressiveness: Double) throws -> MLXArray {
        let key = "\(id)|\(expressiveness)"
        if let style = styles[key] { return style }
        guard let voice = KokoroVoices.voice(id) else { throw CocoaError(.fileNoSuchFile) }
        var floats = try rawStyle(slot: voice.slot)
        if expressiveness != 1 {
            // Push the intonation away from (or toward) the average of all the voices.
            let average = try averageProsodyHalf()
            let k = Float(expressiveness)
            for row in 0..<Self.rows {
                for column in Self.prosodyStart..<Self.width {
                    let i = row * Self.width + column
                    let mean = average[row * (Self.width - Self.prosodyStart) + column - Self.prosodyStart]
                    floats[i] = mean + k * (floats[i] - mean)
                }
            }
        }
        let style = MLXArray(floats, [Self.rows, 1, Self.width])
        if styles.count > 12 { styles.removeAll() }
        styles[key] = style
        return style
    }

    /// One voice's style, 510 × 256 floats, from Resources/Kokoro/kokoro-voices.bin.
    private func rawStyle(slot: Int) throws -> [Float] {
        if voiceData == nil {
            let url = Bundle.main.url(forResource: "kokoro-voices", withExtension: "bin")
                ?? Bundle.main.url(forResource: "kokoro-voices", withExtension: "bin", subdirectory: "Kokoro")
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            voiceData = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let voiceData else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = Self.rows * Self.width * MemoryLayout<Float>.size
        let start = slot * bytes
        guard voiceData.count >= start + bytes else { throw CocoaError(.fileReadCorruptFile) }
        return voiceData.subdata(in: start..<(start + bytes)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private func averageProsodyHalf() throws -> [Float] {
        if let averageProsody { return averageProsody }
        let half = Self.width - Self.prosodyStart
        var sum = [Float](repeating: 0, count: Self.rows * half)
        let voices = KokoroVoices.all
        for voice in voices {
            let floats = try rawStyle(slot: voice.slot)
            for row in 0..<Self.rows {
                for column in 0..<half {
                    sum[row * half + column] += floats[row * Self.width + Self.prosodyStart + column]
                }
            }
        }
        let average = sum.map { $0 / Float(voices.count) }
        averageProsody = average
        return average
    }
}

/// Whether Kokoro may use the GPU: only while the app is active. iOS doesn't allow GPU work
/// from the background, and ends the app if a command buffer is sent after it leaves the
/// foreground. When the app is about to go inactive (locking the screen, switching apps),
/// the gate closes and waits for any GPU chunk in flight to finish, so nothing is running on
/// the GPU by the time the app reaches the background. Kokoro carries on on the CPU.
nonisolated final class GPUGate: @unchecked Sendable {
    static let shared = GPUGate()

    private let state = NSLock()
    private var isOpen = true
    /// Held while a chunk runs on the GPU.
    private let inFlight = NSLock()
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        // By name: this class isn't on the main actor. Delivered on the posting (main) thread.
        for name in ["UIApplicationWillResignActiveNotification", "UIApplicationDidEnterBackgroundNotification"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.close()
            })
        }
        observers.append(center.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: nil) { [weak self] _ in
            self?.open()
        })
        // Launched straight into the background (Siri, a Shortcut): start closed.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if UIApplication.shared.applicationState != .active { self?.close() }
            }
        }
    }

    private func open() {
        state.withLock { isOpen = true }
    }

    private func close() {
        state.withLock { isOpen = false }
        // Let a chunk already on the GPU finish (a fraction of a second) before the app moves on.
        if inFlight.lock(before: Date(timeIntervalSinceNow: 2)) { inFlight.unlock() }
    }

    /// Runs `body` with the GPU allowed, or returns nil when the app isn't active.
    func run<T>(_ body: () throws -> T) rethrows -> T? {
        inFlight.lock()
        defer { inFlight.unlock() }
        guard state.withLock({ isOpen }) else { return nil }
        return try body()
    }
}

/// A thread-safe "this request was cancelled" mark, set from any thread.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }

    func check() throws {
        if lock.withLock({ value }) { throw CancellationError() }
    }
}

// MARK: - Text

nonisolated enum KokoroText {
    /// Kokoro reads up to about 510 phonemes at once; sentences of this length stay well under.
    static let chunkLimit = 280

    /// A reply made ready to speak: no markdown, units said in full.
    static func prepare(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: #"(\d)\s?kcal\b"#, with: "$1 calories", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\d)\s?g\b"#, with: "$1 grams", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\d)\s?oz\b"#, with: "$1 ounces", options: .regularExpression)
        result = result.replacingOccurrences(of: " · ", with: ", ")
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits at sentence ends, keeping each piece under `chunkLimit`.
    static func chunks(_ text: String) -> [String] {
        guard text.count > chunkLimit else { return [text] }
        var pieces: [String] = []
        var current = ""
        for sentence in sentences(text) {
            if current.count + sentence.count > chunkLimit, !current.isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespaces))
        }
        return pieces.flatMap { $0.count > chunkLimit * 2 ? halves($0) : [$0] }
    }

    /// Two halves split at the comma (or space) nearest the middle.
    static func halves(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 20 else { return [text] }
        let middle = characters.count / 2
        let commas = characters.indices.filter { characters[$0] == "," || characters[$0] == ";" }
        let spaces = characters.indices.filter { characters[$0] == " " }
        guard let cut = (commas.isEmpty ? spaces : commas).min(by: { Swift.abs($0 - middle) < Swift.abs($1 - middle) }) else { return [text] }
        let first = String(characters[...cut]).trimmingCharacters(in: .whitespaces)
        let second = String(characters[(cut + 1)...]).trimmingCharacters(in: .whitespaces)
        return [first, second].filter { !$0.isEmpty }
    }

    /// Sentences, each with its ending punctuation, for speaking one at a time.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for c in text {
            current.append(c)
            if ".;:?!".contains(c) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
