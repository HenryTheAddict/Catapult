import Foundation
import AVFoundation

/// Framing occurs on bytes, so UTF-8 characters and records may span pipe reads.
nonisolated struct LineFramer {
    private var pending = Data()
    mutating func append(_ data: Data, finish: Bool = false) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[..<index], as: UTF8.self)
            pending.removeSubrange(...index)
            if !line.isEmpty { lines.append(line) }
        }
        if finish && !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        return lines
    }
}

/// Drains both pipes concurrently, delivering ordered records before completion.
nonisolated enum MediaProcess {
    struct Result: Sendable { let code: Int32; let stdout: String; let stderr: String }
    static func run(_ process: Process,
                    onLine: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> Result {
        let cancellation = Cancellation(process)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do { try cancellation.start() } catch {
                    continuation.resume(returning: Result(code: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let capture = Capture()
                let group = DispatchGroup()
                for (pipe, isError) in [(output, false), (errors, true)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        var framer = LineFramer()
                        var collected = Data()
                        while true {
                            let data = pipe.fileHandleForReading.availableData
                            collected.append(data)
                            for line in framer.append(data, finish: data.isEmpty) {
                                DispatchQueue.main.async { onLine(line) }
                            }
                            if data.isEmpty { break }
                        }
                        capture.set(collected, error: isError)
                        group.leave()
                    }
                }
                process.waitUntilExit()
                group.wait()
                let result = capture.result(code: process.terminationStatus)
                DispatchQueue.main.async { continuation.resume(returning: result) }
            }
            }
        } onCancel: { cancellation.cancel() }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let process: Process
        init(_ process: Process) { self.process = process }
        func start() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var output = Data(), errors = Data()
        func set(_ data: Data, error: Bool) {
            lock.lock(); defer { lock.unlock() }
            if error { errors = data } else { output = data }
        }
        func result(code: Int32) -> Result {
            lock.lock(); defer { lock.unlock() }
            return Result(code: code, stdout: String(decoding: output, as: UTF8.self),
                          stderr: String(decoding: errors, as: UTF8.self))
        }
    }
}

nonisolated enum ClipAccuracy: String, Codable, CaseIterable { case accurate, fast }
nonisolated enum MediaSource: Codable, Hashable {
    case online(String)
    case local(URL)
    var isOnline: Bool { if case .online = self { return true }; return false }
    var value: String {
        switch self { case .online(let link): return link; case .local(let file): return file.absoluteString }
    }
}

nonisolated enum MediaTime {
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
            if index > 0 && number >= 60 { return nil }
            if index < parts.count - 1 && number.rounded() != number { return nil }
            total = total * 60 + number
        }
        return total.isFinite ? total : nil
    }
    static func format(_ seconds: Double) -> String {
        let milliseconds = Int64((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        let s = milliseconds / 1000
        return String(format: "%02lld:%02lld:%02lld.%03lld", s / 3600, s / 60 % 60, s % 60, milliseconds % 1000)
    }
    static func valid(start: Double, end: Double, duration: Double) -> Bool {
        start.isFinite && end.isFinite && duration.isFinite && duration > 0 && start >= 0 &&
        end <= duration && end - start >= min(0.25, duration) - 0.000001
    }
}

nonisolated struct TransferProgress {
    struct Stream { var downloaded: Double = 0; var total: Double?; var estimated = false }
    var streams: [String: Stream] = [:]
    var expected: Set<String> = []
    var fraction: Double?
    var isEstimated = false
    mutating func prepare(_ formats: [[String: Any]]) {
        for format in formats {
            guard let id = format["format_id"] as? String else { continue }
            expected.insert(id)
            let size = (format["filesize"] as? NSNumber)?.doubleValue ?? (format["filesize_approx"] as? NSNumber)?.doubleValue
            streams[id] = Stream(total: size, estimated: format["filesize"] == nil)
        }
    }
    mutating func update(id: String, progress: [String: Any]) {
        var stream = streams[id] ?? Stream()
        stream.downloaded = (progress["downloaded_bytes"] as? NSNumber)?.doubleValue ?? stream.downloaded
        if let total = (progress["total_bytes"] as? NSNumber)?.doubleValue, total > 0 {
            stream.total = total; stream.estimated = false
        } else if let estimate = (progress["total_bytes_estimate"] as? NSNumber)?.doubleValue, estimate > 0 {
            stream.total = estimate; stream.estimated = true
        }
        if progress["status"] as? String == "finished", stream.total == nil { stream.total = stream.downloaded }
        streams[id] = stream
        let all = expected.isEmpty ? [stream] : expected.compactMap { streams[$0] }
        if !all.isEmpty && all.allSatisfy({ ($0.total ?? 0) > 0 }) {
            fraction = min(1, max(0, all.reduce(0) { $0 + min($1.downloaded, $1.total!) } / all.reduce(0) { $0 + $1.total! }))
            isEstimated = all.contains { $0.estimated }
        } else {
            fraction = stream.total.flatMap { $0 > 0 ? min(1, max(0, stream.downloaded / $0)) : nil }
            isEstimated = stream.estimated
        }
    }
}

nonisolated enum ClipRecipe {
    static func arguments(input: URL, output: URL, start: Double, end: Double,
                          audioOnly: Bool, accuracy: ClipAccuracy, bitrate: Int,
                          height: Int?, normalize: Bool = false) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                    "-ss", String(format: "%.6f", start), "-i", input.path,
                    "-t", String(format: "%.6f", end - start), "-map_metadata", "0"]
        if audioOnly {
            let codecs = ["mp3": "libmp3lame", "m4a": "aac", "opus": "libopus", "flac": "flac", "wav": "pcm_s16le"]
            args += ["-vn", "-c:a", codecs[output.pathExtension] ?? "aac"]
            if !["flac", "wav"].contains(output.pathExtension) { args += ["-b:a", "\(bitrate)k"] }
            if normalize { args += ["-af", "loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000"] }
        } else if accuracy == .fast {
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        } else {
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", output.pathExtension == "webm" ? "libvpx-vp9" : "libx264"]
            if output.pathExtension != "webm" { args += ["-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p"] }
            args += ["-c:a", output.pathExtension == "webm" ? "libopus" : "aac", "-b:a", "\(bitrate)k"]
            if let height { args += ["-vf", "scale=-2:min(ih\\,\(height))"] }
            if normalize { args += ["-af", "loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000"] }
        }
        if output.pathExtension == "mp4" || output.pathExtension == "m4a" { args += ["-movflags", "+faststart"] }
        return args + ["-progress", "pipe:1", output.path]
    }
}
