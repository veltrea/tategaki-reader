import AVFoundation
import Foundation
import UIKit
import WebKit

// MARK: - セクション動画（読み上げ＋縦書きグロー）レンダラ
//
// 縦書きグローのカラオケ字幕動画を生成する。役割分担:
//   - VOICEVOX 通信 … Swift(URLSession)。foliate:// origin はブラウザ fetch だと CORS/ATS で弾かれる。
//   - Canvas 2D 描画 … オフスクリーン WKWebView の harness（narration-video のレンダラを再利用）。
//   - 動画エンコード … Swift(AVAssetWriter + AVAssetExportSession)。素の WKWebView は
//                     MediaRecorder / canvas.captureStream を持たないため、フレームを 1 枚ずつ
//                     吸い出してネイティブに H.264 化し、VOICEVOX 音声(WAV)を mux する。
//
// この方式はオフライン（リアルタイム録画不要）で決定的。アセットは Resources/foliate/narration/。

// このレンダラは **メインアクタから外して** ある。フレームごとの JPEG デコード・
// CVPixelBuffer への再描画・H.264 への投入をメインスレッドでやると、書き出し中ずっと
// メインスレッドが埋まり、ページ送りやスライダーの操作が詰まって UI が固まる。
// MainActor が要るのは WebView に触る部分だけなので、そこだけ隔離してある
// （`makeEngine` と `NarrationEngine` のメソッド）。
enum VideoNarrationRenderer {
    struct Config: Sendable {
        /// 1 行ぶんの合成済みデータ。VOICEVOX 通信は Swift 側で済ませて渡す。
        struct Line: Sendable {
            var text: String        // 表示テキスト（字幕の掃引に使う・読み替え適用済み）
            var queryJSON: String   // audio_query JSON（speed/pause 適用済み・synthesis と同一）
            var wav: Data           // synthesis の WAV（音声トラックは Swift 側で lineStarts に配置して mux）
        }
        var lines: [Line]
        /// 配色テーマ（"dark" | "sepia" | "light"）。
        var theme: String
        /// 書字方向（"vertical" = 縦書き / "horizontal" = 横書き）。本の dir から自動決定する。
        var orientation: String = "vertical"
        var width: Int = 720
        var height: Int = 1280
        var fontSize: Int = 48
        var fps: Int = 24

        var colors: (bg: String, fg: String, accent: String) {
            switch theme {
            case "light": return ("#ffffff", "#1a1a1a", "#e0a020")
            case "sepia": return ("#f4ecd8", "#5b4636", "#c0803a")
            default:      return ("#0a0a0f", "#f5f5f5", "#00d0ff")
            }
        }

        /// 書字方向に応じた既定サイズ。縦書き=縦長(720x1280) / 横書き=横長(1280x720)。
        static func make(lines: [Line], theme: String, vertical: Bool) -> Config {
            Config(
                lines: lines, theme: theme,
                orientation: vertical ? "vertical" : "horizontal",
                width: vertical ? 720 : 1280,
                height: vertical ? 1280 : 720)
        }
    }

    struct Output: Sendable {
        var data: Data
        var ext: String
    }

    enum RenderError: Error, Sendable { case prepareFailed(String), noFrames, writerFailed(String) }

    /// harness を載せたオフスクリーン WebView を用意する。WebView に触るのでここだけ MainActor。
    @MainActor
    private static func makeEngine(width: Int, height: Int) -> NarrationEngine {
        let engine = NarrationEngine()
        let web = engine.makeWebView()
        let host = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        web.frame = CGRect(x: 0, y: 0, width: width, height: height)
        web.isHidden = true
        host?.addSubview(web)
        return engine
    }

    /// 動画を生成する。onProgress は status 表示用（呼び出し側で MainActor へ渡すこと）。
    /// この関数自体はメインアクタ外で走る。メインスレッドを触るのは WebView 呼び出しだけ。
    static func render(
        config: Config,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Output? {
        let engine = await makeEngine(width: config.width, height: config.height)
        // teardown は removeFromSuperview まで面倒を見る（MainActor 隔離なので Task で投げる）。
        defer { Task { @MainActor in engine.teardown() } }

        do {
            return try await withTaskCancellationHandler {
                // 1) harness ロード完了を待つ。
                try await engine.waitReady(timeout: 15)
                if Task.isCancelled { return nil }

                // 2) prepare: タイムライン + レイアウト構築、結合音声(WAV)を受け取る。
                onProgress(String(localized: "動画を準備中…"))
                let payload: [String: Any] = [
                    // webview へは字幕タイミング用の text/query のみ（音声は Swift が持つ）。
                    "lines": config.lines.map { ["text": $0.text, "query": $0.queryJSON] },
                    "orientation": config.orientation,
                    "fontSize": config.fontSize,
                    "width": config.width,
                    "height": config.height,
                    "bg": config.colors.bg,
                    "fg": config.colors.fg,
                    "accent": config.colors.accent,
                    "fontFamily": "'Hiragino Mincho ProN', 'YuMincho', serif",
                ]
                let arg = await FoliateEngine.jsonArg(payload)
                guard let prepStr = await engine.callAsync("return await window.__narr.prepare(\(arg))") as? String,
                      let prep = decode(prepStr) else {
                    throw RenderError.prepareFailed("prepare no result")
                }
                guard (prep["ok"] as? Bool) == true,
                      let totalDuration = (prep["totalDuration"] as? NSNumber)?.doubleValue,
                      let lineStarts = (prep["lineStarts"] as? [Any])?
                        .compactMap({ ($0 as? NSNumber)?.doubleValue }),
                      lineStarts.count == config.lines.count else {
                    throw RenderError.prepareFailed((prep["error"] as? String) ?? "prepare failed")
                }
                if Task.isCancelled { return nil }

                // 3) 音声トラック: 各行 WAV を lineStarts に配置して 1 本に結合（webview の掃引と同期）。
                let placed = zip(config.lines, lineStarts).map { (wav: $0.0.wav, start: $0.1) }
                guard let wavData = WAV.compose(lines: placed, totalDuration: totalDuration) else {
                    throw RenderError.prepareFailed("audio compose failed")
                }

                // 4) フレームを 1 枚ずつ吸い出して H.264 で書き出す（無音動画）。
                let silentURL = tmpURL("narr-video", "mp4")
                try await encodeVideo(
                    engine: engine, config: config,
                    totalDuration: totalDuration, to: silentURL,
                    onProgress: onProgress)
                if Task.isCancelled { try? FileManager.default.removeItem(at: silentURL); return nil }

                // 5) 音声(WAV)を書き出し、動画と mux して最終 MP4 に。
                onProgress(String(localized: "音声と結合中…"))
                let wavURL = tmpURL("narr-audio", "wav")
                try wavData.write(to: wavURL)
                let finalURL = tmpURL("narr-final", "mp4")
                try await mux(video: silentURL, audio: wavURL, to: finalURL)

                let data = try Data(contentsOf: finalURL)
                for u in [silentURL, wavURL, finalURL] { try? FileManager.default.removeItem(at: u) }
                return Output(data: data, ext: "mp4")
            } onCancel: {
                Task { @MainActor in engine.abort() }
            }
        } catch {
            onProgress(String(format: String(localized: "動画生成に失敗: %@"),
                              (error as? RenderError).map(describe) ?? error.localizedDescription))
            return nil
        }
    }

    // MARK: - フレーム吸い出し → H.264

    /// フレーム吸い出し → H.264。メインアクタ外で走らせるのが要点で、メインスレッドに
    /// 乗るのは `engine.callAsync`（1フレーム1回の JS 呼び出し）だけ。デコード・
    /// pixelBuffer 生成・エンコード投入はバックグラウンドで行う。
    private static func encodeVideo(
        engine: NarrationEngine, config: Config,
        totalDuration: Double, to url: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        let fps = config.fps
        let w = config.width, h = config.height
        let frameCount = max(1, Int((totalDuration + 0.3) * Double(fps)))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw RenderError.writerFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        for i in 0 ..< frameCount {
            if Task.isCancelled { break }
            let t = Double(i) / Double(fps)
            // harness に t 秒のフレームを描かせて JPEG data URL を得る。
            let dataURL = await engine.callAsync(
                "return window.__narr.frame(\(String(format: "%.4f", t)))") as? String
            guard let dataURL, let cg = cgImage(fromDataURL: dataURL) else { continue }
            guard let pool = adaptor.pixelBufferPool,
                  let pb = pixelBuffer(from: cg, width: w, height: h, pool: pool) else { continue }
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps)))
            if i % (fps * 2) == 0 {
                let pct = Int(Double(i) / Double(frameCount) * 100)
                onProgress(String(format: String(localized: "動画を書き出し中… %lld%%"), pct))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "finish failed")
        }
    }

    // MARK: - mux（無音動画 + WAV → MP4）

    private static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        let vDur = try await vAsset.load(.duration)

        if let vt = try await vAsset.loadTracks(withMediaType: .video).first,
           let vTrack = comp.addMutableTrack(withMediaType: .video,
                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vt, at: .zero)
        }
        if let at = try await aAsset.loadTracks(withMediaType: .audio).first,
           let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = try await aAsset.load(.duration)
            // 音声は動画尺にクランプ（末尾の無音余白ぶんは切らない＝短い方に合わせる）。
            let dur = CMTimeMinimum(vDur, aDur)
            try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: at, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.writerFailed("no export session")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        if export.status != .completed {
            throw RenderError.writerFailed(export.error?.localizedDescription ?? "export failed")
        }
    }

    // MARK: - ヘルパ

    private static func decode(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func describe(_ e: RenderError) -> String {
        switch e {
        case .prepareFailed(let m): return m
        case .noFrames: return "no frames"
        case .writerFailed(let m): return m
        }
    }

    private static func tmpURL(_ name: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
    }

    /// "data:image/jpeg;base64,..." → CGImage。
    private static func cgImage(fromDataURL s: String) -> CGImage? {
        guard let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let ui = UIImage(data: data) else { return nil }
        return ui.cgImage
    }

    /// CGImage → 32BGRA CVPixelBuffer（上下反転を補正して描画）。
    private static func pixelBuffer(
        from image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // CGImage(UIImage 由来)を CVPixelBuffer 用コンテキストへそのまま描くと正しい向きになる
        // （AVAssetWriter が期待する行順と一致）。ここで y 反転すると上下逆になるため入れない。
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}

// MARK: - narration 専用のオフスクリーン WKWebView ラッパ
// FoliateSchemeHandler（root=Resources/foliate）を再利用し harness を配信する。メッセージ名 "narration"。

@MainActor
final class NarrationEngine: NSObject, WKScriptMessageHandler {
    private(set) var webView: WKWebView?
    private var readyCont: CheckedContinuation<Void, Never>?
    private var isReady = false

    @discardableResult
    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(FoliateSchemeHandler(provider: FoliateBookProvider()),
                                   forURLScheme: FoliateSchemeHandler.scheme)
        config.userContentController.add(self, name: "narration")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = true
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        webView = web
        web.load(URLRequest(url: URL(string: "foliate:///app/narration/harness.html")!))
        return web
    }

    func teardown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "narration")
        webView?.removeFromSuperview()
        webView = nil
    }

    /// harness の narr-ready を待つ（timeout 秒で諦める）。
    func waitReady(timeout: Double) async throws {
        if isReady { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyCont = cont
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = readyCont { readyCont = nil; c.resume() }
            }
        }
    }

    func abort() {
        Task { await callAsync("window.__narr && window.__narr.abort()") }
    }

    nonisolated func userContentController(
        _ ucc: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        // message.body は MainActor 隔離なので、読むところから MainActor 内で行う。
        Task { @MainActor in
            guard let body = message.body as? [String: Any],
                  (body["type"] as? String) == "narr-ready" else { return }
            self.isReady = true
            if let c = self.readyCont { self.readyCont = nil; c.resume() }
        }
    }

    /// async JS（Promise を返す式・await 式）を実行して結果を得る。
    @discardableResult
    func callAsync(_ body: String) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
    }
}
