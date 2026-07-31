import SwiftUI

/// メニューバーの「表示」に並べる、見え方の項目。
///
/// 環境設定の「表示」タブと同じ内容を、シートを開かずに切り替えられるようにしたもの。
/// 効く先は状況で変わる（どちらもツールバーの各ボタンと同じ経路を通る）:
///   - 本を開いているとき: 文字サイズ・行間・テーマ・表示モードは全書籍共通の設定を書き換え、
///     書字方向・綴じ方向・見開きは **その本の指定** として覚える。既定と同じ値を選んだ場合は
///     本ごとの指定を持たない（あとで既定を変えたときに追従させるため）。
///   - 書棚にいるとき: どれも全書籍の既定（環境設定と同じ値）を書き換える。
///
/// 「言語」だけはここに出さない。反映がアプリ再起動後なので、押した瞬間に変わる
/// メニュー項目の体裁に合わないため（環境設定の「表示」タブに残してある）。
struct DisplayCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // チェックマークには「いまその本に効いている値」を出したいので、本を開いている間は
        // ReaderModel を @ObservedObject で見る層を挟む（AppModel だけを見ていると、
        // ツールバーから書字方向を変えてもメニューのチェックが古いままになる）。
        if let reader = model.activeReader {
            ReaderDisplayCommands(model: model, reader: reader)
        } else {
            DisplayCommandItems(model: model, reader: nil)
        }
    }
}

/// メニューバーの「移動」に並べるページ送り。
///
/// 「次／前」は本の綴じ方向に依らない**論理的な向き**で、解決は ReaderModel が持つ
/// pageStep(forward:) に任せる（左右の意味は縦書き・右綴じで反転するため、
/// ビュー側で向きを決めない設計にしてある）。本を開いていないときは淡色表示。
struct NavigationCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // 本を開いているかで丸ごと差し替える。項目ごとや Group への .disabled は、
        // 分岐と Divider が混ざったメニューでは効かず有効のままになった（実測）。
        if let reader = model.activeReader {
            ReaderNavigationCommands(reader: reader)
        } else {
            Group {
                Button("次のページ") { }
                Button("前のページ") { }
                Divider()
                Button("しおりを追加") { }
                Button("しおりを開く") { }
            }
            .disabled(true)
        }
        // 自動ページ送りは開いている本に対する操作だが、稼働中の状態（残り秒・停止）は
        // 本を閉じても見えるようにしておく（＝分岐の外に置き、項目ごとに淡色化する）。
        Divider()
        Menu("自動ページ送り") {
            AutoPagerMenuItems(model: model, pager: model.autoPager,
                               enabled: model.activeReader != nil)
        }
    }
}

/// ページ送りとサイドバーの状態をメニューへ反映させる層。
private struct ReaderNavigationCommands: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        Button("次のページ") { Task { await reader.pageStep(forward: true) } }
            .keyboardShortcut("]", modifiers: .command)
        Button("前のページ") { Task { await reader.pageStep(forward: false) } }
            .keyboardShortcut("[", modifiers: .command)
        Divider()
        // いま読んでいる位置にしおりを挟む（ツールバーのしおりボタンと同じ）。
        Button("しおりを追加") { reader.addBookmark() }
        // 開いている間はチェックが付く。目次とは排他（toggleBookmarks が面倒を見る）。
        Toggle("しおりを開く", isOn: Binding(
            get: { reader.showBookmarks },
            set: { _ in reader.toggleBookmarks() }
        ))
    }
}

/// メニューバー「ファイル > 書き出し」。リーダー下部の波形・フィルムボタンと同じ経路を通る。
///
/// 対象はどちらも「いま読んでいるセクション」で、書き出し先は環境設定の音声の保存先
///（既定はダウンロード）。書き出し中と読み上げ中は、同時に走らせないよう淡色にする。
struct ExportCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu("書き出し") {
            if let reader = model.activeReader {
                ReaderExportCommands(reader: reader)
            } else {
                // 本を開いていないときは書き出す対象がいないので淡色にする。
                // ここは Group にまとめて .disabled を付けても効かない（サブメニューの
                // 中では伝播しない。実測で有効のままだった）ので、項目ごとに付ける。
                Button("オーディオを書き出し…") { }.disabled(true)
                Button("動画を書き出し…") { }.disabled(true)
            }
        }
    }
}

/// 書き出しの進行状況（保存中・読み上げ中）をメニューへ反映させる層。
private struct ReaderExportCommands: View {
    @ObservedObject var reader: ReaderModel

    /// 音声・動画は同じ合成経路を使うので同時には走らせない。読み上げ中も同様。
    private var busy: Bool {
        !reader.engineReady || reader.isSavingAudio || reader.isSavingVideo || reader.canStop
    }

    var body: some View {
        Button("オーディオを書き出し…") { reader.saveCurrentSectionAudio() }
            .disabled(busy)
        Button("動画を書き出し…") { reader.saveCurrentSectionVideo() }
            .disabled(busy)
    }
}

/// メニューバーの「読み上げ」。ツールバーの再生・停止ボタンと同じ経路を通る。
///
/// ショートカットは付けない。本文にフォーカスがある間は Space＝再生/一時停止、
/// Enter・Esc＝停止が既に効いており、同じキーをメニューに置くと検索欄などの
/// 文字入力までメニューに奪われるため。
struct SpeechCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let reader = model.activeReader {
            ReaderSpeechCommands(reader: reader)
        } else {
            // 本を開いていないときは読む相手がいないので、位置は保ったまま淡色にする。
            Group {
                Button("読み上げ開始") { }
                Button("読み上げ停止") { }
                Divider()
                Button("読み上げ辞書…") { }
            }
            .disabled(true)
        }
        // スリープタイマーは本を開いていなくても操作できる（走っているタイマーを
        // 書棚へ戻ってから解除したい、という場面があるため）。
        Divider()
        Menu("スリープタイマー") {
            SleepTimerMenuItems(model: model, timer: model.sleepTimer)
        }
    }
}

/// 読み上げの状態（再生中か・停止できるか）をメニューへ反映させる層。
private struct ReaderSpeechCommands: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        // 一時停止中は「開始」で続きから再開する（ツールバーの再生ボタンと同じ挙動）。
        Button("読み上げ開始") { reader.togglePlayPause() }
            .disabled(!reader.engineReady || reader.isPlaying)
        Button("読み上げ停止") { reader.stopSpeaking() }
            .disabled(!reader.canStop)
        Divider()
        // 単語の読み替えルール（ツールバーの本アイコンと同じシート）。
        Button("読み上げ辞書…") { reader.showDictionary = true }
    }
}

/// 開いている本の状態をメニューへ反映させるためだけの層。
private struct ReaderDisplayCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reader: ReaderModel

    var body: some View { DisplayCommandItems(model: model, reader: reader) }
}

private struct DisplayCommandItems: View {
    @ObservedObject var model: AppModel
    /// 開いているリーダー。nil（書棚）のときは全書籍の既定だけを書き換える。
    var reader: ReaderModel?

    var body: some View {
        textSizeItems
        Divider()
        lineHeightItems
        Divider()
        appearanceItems
        Divider()
        layoutItems
    }

    // MARK: 項目

    // ショートカットの制約: Catalyst は ⌘+ / ⌘-（素の）を UIKit 側が押さえており、
    // 同じキーを付けた項目はメニューから黙って捨てられる（実際に消えた）。
    // 代わりに ⌘=（ブラウザの拡大と同じ）と ⇧⌘- を使う。
    private var textSizeItems: some View {
        Group {
            Button("文字を大きく") { changeFontSize(by: ReadingSettings.fontSizeStep) }
                .keyboardShortcut("=", modifiers: .command)
            Button("文字を小さく") { changeFontSize(by: -ReadingSettings.fontSizeStep) }
                .keyboardShortcut("-", modifiers: [.command, .shift])
            Button("文字サイズを標準に戻す") { setFontSize(ReadingSettings().fontSize) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    private var lineHeightItems: some View {
        Group {
            Button("行間を広く") { changeLineHeight(by: ReadingSettings.lineHeightStep) }
            Button("行間を狭く") { changeLineHeight(by: -ReadingSettings.lineHeightStep) }
            Button("行間を標準に戻す") { setLineHeight(ReadingSettings().lineHeight) }
        }
    }

    private var appearanceItems: some View {
        Group {
            Picker("テーマ", selection: themeBinding) {
                Text("自動").tag("auto")
                Text("ライト").tag("light")
                Text("セピア").tag("sepia")
                Text("ダーク").tag("dark")
            }
            Picker("表示モード", selection: renderModeBinding) {
                ForEach(RenderMode.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var layoutItems: some View {
        Group {
            Picker("書字方向", selection: writingModeBinding) {
                ForEach(WritingMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("綴じ方向", selection: bindingDirectionBinding) {
                ForEach(BindingDirection.allCases) { Text($0.label).tag($0) }
            }
            Picker("画像ページの見開き", selection: imageSpreadBinding) {
                ForEach(SpreadMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("本文の見開き", selection: textSpreadBinding) {
                ForEach(SpreadMode.allCases) { Text($0.label).tag($0) }
            }
            aspectMenu
        }
    }

    /// 画像の比率の強制。判型は本ごとにしか意味がないので、既定は持たず本を開いている
    /// ときだけ選べる（元はツールバーのボタンだった）。
    private var aspectMenu: some View {
        Menu("画像の比率") {
            Button("固定しない") { reader?.setForcedAspect(nil) }
            if let detected = reader?.detectedAspect {
                Section("この本の判型") {
                    Button(detected.label) { reader?.setForcedAspect(detected) }
                }
            }
            Section("判型を選ぶ") {
                ForEach(AspectRatio.presets, id: \.storageString) { preset in
                    Button(preset.label) { reader?.setForcedAspect(preset) }
                }
            }
            Section {
                Button("任意の比率…") { reader?.requestAspectInput() }
            }
        }
        .disabled(reader == nil)
    }

    // MARK: 文字サイズ・行間

    private func changeFontSize(by delta: Double) {
        if let reader = reader { reader.changeFontSize(by: delta) }
        else { setFontSize(model.settings.fontSize + delta) }
    }

    private func setFontSize(_ value: Double) {
        if let reader = reader { reader.setFontSize(value) }
        else {
            model.editSettings { $0.fontSize = value.clamped(to: ReadingSettings.fontSizeRange) }
        }
    }

    private func changeLineHeight(by delta: Double) {
        if let reader = reader { reader.changeLineHeight(by: delta) }
        else { setLineHeight(model.settings.lineHeight + delta) }
    }

    private func setLineHeight(_ value: Double) {
        if let reader = reader { reader.setLineHeight(value) }
        else {
            model.editSettings { $0.lineHeight = value.clamped(to: ReadingSettings.lineHeightRange) }
        }
    }

    // MARK: 選択（開いている本があればその本へ、無ければ既定へ）

    private var themeBinding: Binding<String> {
        Binding(
            get: { model.settings.theme },
            set: { new in
                if let reader = reader { reader.setTheme(new) }
                else { model.editSettings { $0.theme = new } }
            })
    }

    private var renderModeBinding: Binding<RenderMode> {
        Binding(
            get: { reader?.renderMode ?? RenderMode(rawValue: model.settings.renderMode) ?? .friendly },
            set: { new in
                if let reader = reader { reader.setRenderMode(new) }
                else { model.editSettings { $0.renderMode = new.rawValue } }
            })
    }

    private var writingModeBinding: Binding<WritingMode> {
        Binding(
            get: { reader?.writingMode ?? WritingMode(rawValue: model.settings.writingMode) ?? .auto },
            set: { new in
                if let reader = reader { reader.setWritingMode(new) }
                else { model.editSettings { $0.writingMode = new.rawValue } }
            })
    }

    private var bindingDirectionBinding: Binding<BindingDirection> {
        Binding(
            get: { reader?.bindingDirection ?? BindingDirection(rawValue: model.settings.bindingDirection) ?? .auto },
            set: { new in
                if let reader = reader { reader.setBindingDirection(new) }
                else { model.editSettings { $0.bindingDirection = new.rawValue } }
            })
    }

    private var imageSpreadBinding: Binding<SpreadMode> {
        Binding(
            get: { reader?.imageSpread ?? SpreadMode(rawValue: model.settings.imageSpread) ?? .auto },
            set: { new in
                if let reader = reader { reader.setImageSpread(new) }
                else { model.editSettings { $0.imageSpread = new.rawValue } }
            })
    }

    private var textSpreadBinding: Binding<SpreadMode> {
        Binding(
            get: { reader?.textSpread ?? SpreadMode(rawValue: model.settings.textSpread) ?? .auto },
            set: { new in
                if let reader = reader { reader.setTextSpread(new) }
                else { model.editSettings { $0.textSpread = new.rawValue } }
            })
    }
}
