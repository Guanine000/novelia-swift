// SPDX-License-Identifier: LGPL-3.0-only
// Protocol adapter informed by rany2/edge-tts, Copyright (c) 2025- rany <rany@riseup.net>.
// Swift adaptation: Copyright (C) 2026 Novelia iOS contributors; modified 2026-11-05.
// Upstream bd44c1d1aaebdc1db7f47456ee12431b42ec7cac; see bundled edge-tts-LICENSE.txt.
import Foundation

/// 独立匿名会话：不使用小说账号、浏览器 Cookie、凭据或磁盘 HTTP 缓存。
/// Edge 消费端协议不是有稳定性承诺的 Azure API；失败向上传递，不静默换服务上传正文。
actor EdgeSpeechClient: CloudSpeechSynthesizing {
    enum Failure: LocalizedError, CloudSpeechRetryableError {
        var shouldRetry: Bool {
            switch self { case .timedOut, .unavailable: return true; default: return false }
        }
        case invalidVoice, invalidText, malformedFrame, tooLarge, noAudio, timedOut, unavailable, rejected
        var errorDescription: String? {
            switch self {
            case .invalidVoice: return "此 Edge 音色不可用，请重新选择。"
            case .invalidText: return "这段正文无法交给 Edge 合成。"
            case .malformedFrame, .noAudio: return "Edge 未返回有效音频，请重试或改用本地朗读。"
            case .tooLarge: return "Edge 返回的音频过大，已停止接收。"
            case .timedOut: return "Edge 合成超时，请重试或改用本地朗读。"
            case .rejected: return "Edge 服务拒绝了朗读请求，请重试或改用本地朗读。"
            case .unavailable: return "暂时无法连接 Edge 朗读服务，请检查网络或改用本地朗读。"
            }
        }
    }
    // 微软消费端协议的公开客户端标识，不是用户 API key。
    private static let clientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config)
    }

    func audio(text: String, voice: String, rate: Double) async throws -> Data {
        try await synthesis(text: text, voice: voice, rate: rate).data
    }
    func synthesis(text: String, voice: String, rate: Double) async throws -> CloudSpeechAudio {
        try await synthesis(text: text, voice: voice, rate: rate, pitch: 0)
    }
    func synthesis(text: String, voice: String, rate: Double, pitch: Double) async throws -> CloudSpeechAudio {
        guard EdgeSpeechVoices.validIdentifier(voice) else { throw Failure.invalidVoice }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CloudSpeechText.escapedUTF8Count(text) <= CloudSpeechText.maximumEscapedUTF8 else { throw Failure.invalidText }
        var now = Date()
        // 仅时钟误差可按服务 Date 纠正一次；其他 403 不无限重试。
        for attempt in 0..<2 {
            let socket = session.webSocketTask(with: Self.request(at: now))
            socket.maximumMessageSize = 1_024 * 1_024
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            let requestDate = now
            do {
                return try await withTaskCancellationHandler(operation: {
                    try await withThrowingTaskGroup(of: CloudSpeechAudio.self) { group in
                        group.addTask {
                            try await socket.send(.string(Self.configuration(at: requestDate)))
                            try await socket.send(.string(Self.ssml(text: text, voice: voice, rate: rate, at: requestDate, pitch: pitch)))
                            return try await Self.receiveAudio(from: socket)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 45_000_000_000)
                            socket.cancel(with: .goingAway, reason: nil)
                            throw Failure.timedOut
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                }, onCancel: { socket.cancel(with: .goingAway, reason: nil) })
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 0, let response = socket.response as? HTTPURLResponse,
                   response.statusCode == 403, let raw = response.value(forHTTPHeaderField: "Date"),
                   let server = Self.serverDate(raw), abs(server.timeIntervalSince(now)) > 1,
                   abs(server.timeIntervalSince(now)) < 86_400 {
                    now = server
                    continue
                }
                if let status = (socket.response as? HTTPURLResponse)?.statusCode,
                   (400..<500).contains(status), status != 408, status != 429 { throw Failure.rejected }
                if let known = error as? Failure { throw known }
                throw Failure.unavailable
            }
        }
        throw Failure.unavailable
    }

    /// 音色目录沿用匿名隔离会话，不携带小说账号，也不发送正文。
    func voices() async throws -> [SpeechVoiceOption] {
        var now = Date()
        for attempt in 0..<2 {
            var request = Self.request(at: now)
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = "https"
            url.path = "/consumer/speech/synthesize/readaloud/voices/list"
            url.queryItems = [
                URLQueryItem(name: "trustedclienttoken", value: Self.clientToken),
                .init(name: "Sec-MS-GEC", value: EdgeSpeechToken.value(at: now, clientToken: Self.clientToken)),
                .init(name: "Sec-MS-GEC-Version", value: "2-143.0.3650.75")
            ]
            request.url = url.url; request.timeoutInterval = 15
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
                if response.statusCode == 403, attempt == 0,
                   let raw = response.value(forHTTPHeaderField: "Date"), let server = Self.serverDate(raw),
                   abs(server.timeIntervalSince(now)) > 1, abs(server.timeIntervalSince(now)) < 86_400 {
                    now = server; continue
                }
                guard response.statusCode == 200 else { throw Failure.unavailable }
                return try Self.voiceOptions(data)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let failure = error as? Failure { throw failure }
                throw Failure.unavailable
            }
        }
        throw Failure.unavailable
    }
    static func voiceOptions(_ data: Data) throws -> [SpeechVoiceOption] {
        guard data.count <= 2 * 1_024 * 1_024 else { throw Failure.tooLarge }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 2_000 else { throw Failure.malformedFrame }
        let result = EdgeSpeechVoices.sanitized(rows.compactMap { row in
            guard let identifier = row["ShortName"] as? String, let language = row["Locale"] as? String else { return nil }
            let name = (row["LocalName"] ?? row["FriendlyName"]) as? String ?? identifier
            return SpeechVoiceOption(identifier: identifier, name: name, language: language)
        })
        guard !result.isEmpty else { throw Failure.malformedFrame }
        return result
    }
    private static func request(at date: Date) -> URLRequest {
        var url = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        url.queryItems = [URLQueryItem(name: "TrustedClientToken", value: clientToken),
                          .init(name: "ConnectionId", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
                          .init(name: "Sec-MS-GEC", value: EdgeSpeechToken.value(at: date, clientToken: clientToken)),
                          .init(name: "Sec-MS-GEC-Version", value: "2-143.0.3650.75")]
        var request = URLRequest(url: url.url!)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // 每个请求随机生成，不读取/保存用户 Cookie。
        request.setValue("muid=\(UUID().uuidString.replacingOccurrences(of: "-", with: ""));", forHTTPHeaderField: "Cookie")
        return request
    }
    private static func timestamp(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return format.string(from: date)
    }
    private static func serverDate(_ raw: String) -> Date? {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: raw)
    }
    private static func configuration(at date: Date) -> String {
        "X-Timestamp:\(timestamp(date))\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" +
        "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"true\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
    }
    static func ssml(text: String, voice: String, rate: Double, at date: Date, pitch: Double = 0) -> String {
        let parts = voice.split(separator: "-")
        let name = parts.count >= 3 ? "Microsoft Server Speech Text to Speech Voice (\(parts.dropLast().joined(separator: "-")), \(parts.last!))" : voice
        let normalized = min(1, max(0, rate.isFinite ? rate : 0.5))
        let percent = Int((normalized <= 0.5 ? (normalized - 0.5) * 100 : (normalized - 0.5) * 200).rounded())
        let rateValue = (percent >= 0 ? "+" : "") + String(percent) + "%"
        let hz = Int((min(1, max(-1, pitch.isFinite ? pitch : 0)) * 50).rounded())
        let pitchValue = (hz >= 0 ? "+" : "") + String(hz) + "Hz"
        let xml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(escape(name))'><prosody pitch='\(pitchValue)' rate='\(rateValue)' volume='+0%'>\(escape(text))</prosody></voice></speak>"
        return "X-RequestId:\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp(date))Z\r\nPath:ssml\r\n\r\n\(xml)"
    }
    static func escape(_ text: String) -> String {
        var value = ""
        for scalar in text.unicodeScalars {
            if scalar.value < 32 && scalar != "\t" && scalar != "\n" && scalar != "\r" { value.append(" "); continue }
            switch scalar {
            case "&": value += "&amp;"
            case "<": value += "&lt;"
            case ">": value += "&gt;"
            case "\"": value += "&quot;"
            case "'": value += "&apos;"
            default: value.unicodeScalars.append(scalar)
            }
        }
        return value
    }
    static func audioPayload(_ frame: Data) throws -> Data {
        guard frame.count >= 2 else { throw Failure.malformedFrame }
        let bytes = Array(frame.prefix(2)); let length = Int(bytes[0]) * 256 + Int(bytes[1])
        guard length <= frame.count - 2,
              let headers = String(data: frame.subdata(in: 2..<(2+length)), encoding: .utf8) else { throw Failure.malformedFrame }
        let lines = headers.components(separatedBy: "\r\n")
        guard lines.contains("Path:audio") else { throw Failure.malformedFrame }
        let payload = frame.subdata(in: (2+length)..<frame.count)
        guard payload.isEmpty || lines.contains("Content-Type:audio/mpeg") else { throw Failure.malformedFrame }
        return payload
    }
    /// 元数据偏移以 100ns 为单位，与同一次合成的播放器时间对应；坏元数据不影响音频。
    static func sentenceBoundaries(_ data: Data) -> [CloudSpeechBoundary] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["Metadata"] as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard value["Type"] as? String == "SentenceBoundary",
                  let body = value["Data"] as? [String: Any],
                  let offset = body["Offset"] as? NSNumber, let duration = body["Duration"] as? NSNumber,
                  let text = body["text"] as? [String: Any], let raw = text["Text"] as? String,
                  offset.doubleValue >= 0, duration.doubleValue >= 0 else { return nil }
            let decoded = raw.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            return CloudSpeechBoundary(time: offset.doubleValue / 10_000_000,
                                       duration: duration.doubleValue / 10_000_000, text: decoded)
        }
    }
    private static func receiveAudio(from socket: URLSessionWebSocketTask) async throws -> CloudSpeechAudio {
        var result = Data()
        var boundaries: [CloudSpeechBoundary] = []
        while true {
            try Task.checkCancellation()
            switch try await socket.receive() {
            case .data(let frame):
                result.append(try audioPayload(frame))
                guard result.count <= 8 * 1_024 * 1_024 else { throw Failure.tooLarge }
            case .string(let message):
                let headers = message.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
                if headers.contains("Path:turn.end") {
                    guard !result.isEmpty else { throw Failure.noAudio }
                    return CloudSpeechAudio(data: result, boundaries: boundaries.sorted { $0.time < $1.time })
                }
                if headers.contains("Path:audio.metadata"), let separator = message.range(of: "\r\n\r\n") {
                    boundaries += sentenceBoundaries(Data(message[separator.upperBound...].utf8))
                    guard boundaries.count <= 4_096 else { throw Failure.tooLarge }
                }
            @unknown default: throw Failure.malformedFrame
            }
        }
    }
}
