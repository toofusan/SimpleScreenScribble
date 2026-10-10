# ScreenNote代替の画面注釈アプリ（macOS）

## 目的
画面共有しながらのライブ説明と、開発中Webサイトへのテキスト補足＋画像共有の両方に使う個人用ツール。
既存のScreenNoteは「テキストの扱いが弱い」点が不満で、そこを主眼に自作する。

## 採用方式
**ライブオーバーレイ型**（透明パネルを最前面に常駐させ、実画面の上に直接描く）。
キャプチャ→注釈型（Skitch/Shottr方式）は検討のうえ不採用。画面共有中の実演に使えないため。
書き出しが必要になったら、オーバーレイ表示中にmacOS標準のスクショを撮る運用で足りる。

## 技術構成
- Swift + AppKit中心（SwiftUIはMenuBarExtraと設定画面のみ）
- メニューバー常駐：`LSUIElement = YES`
- グローバルホットキー：
  - 主トリガー＝**左右Shift同時押し**（`ShiftChordMonitor`が`flagsChanged`をグローバル監視して判定）
  - 補助トリガー＝`sindresorhus/KeyboardShortcuts`（SPM導入済み・既定⌃⌥⌘A、Recorderで変更可）
- App Sandbox：**無効**（個人利用のため。配布予定なし）
- 権限：**いずれのTCC権限も不要**（画面収録・アクセシビリティ・入力監視すべて不要）。
  修飾キーのみのホットキーはCarbon(RegisterEventHotKey)で扱えないため`flagsChanged`のグローバル監視を採用するが、
  `flagsChanged`は修飾キーの状態変化のみで文字情報を含まないためTCCの保護対象外。
  `NSEvent.addGlobalMonitorForEvents`で無権限のまま全アプリから検知できる（文字キーの監視だけが権限を要する）。
  補助ホットキー（KeyboardShortcuts）はCarbonベースで元々権限不要。権限関連のTCC処理は書かないこと
  （※過去に「アクセシビリティ必要」「入力監視必要」と誤記していたが、実機検証で不要と確定）

## 現状（M5完了）
M1〜M5完了。基本機能は一通り実装済み。
- M1：全ディスプレイに透明パネル常駐、フルスクリーン被り／ESC消去／画面共有写り込みを確認済み
- M2：3状態（hidden/passthrough/drawing）切り替え＋フリーハンド描画
- M3：`[Annotation]`モデル導入、描画は`AnnotationRenderer.draw(_:in:scale:)`に一本化。
  テキスト＝クリックで横流し入力／ドラッグで幅指定ボックス／シングルクリックで再編集（キャレット位置）／
  エッジ選択→移動・角ハンドルでリサイズ・Delete削除／バッキングプレート既定オン
- M4：矢印(`.arrow`)・矩形(`.rect`)、Undo/Redo（全体スナップショット）、全消去、
  フローティングツールバー（別`NSPanel`＝`ToolbarPanel`、色/太さ/ツール/Undo/全消去）。
  ツール・色・太さ・文字サイズは`DrawingState`（`@Observable`）で共有
- M5：設定の永続化（色/太さ/不透明度/文字サイズ/矩形塗り/最後のツールを`DrawingState`が
  UserDefaultsへ保存・復元）、表示/非表示・描画/素通し切替のホットキーを
  `KeyboardShortcuts.Recorder`で変更可能に（主トリガーの修飾キーチョードは従来どおり固定で併存）。
  ※権限ガイドUIも一旦入れたが、`flagsChanged`監視は無権限で動くと判明し撤去

### 操作まとめ
- 表示/非表示：左右Shift同時押し（補助ホットキーを設定画面のRecorderで追加可）
- 描画/素通し切替：Ctrl+Shift（補助で⌃⌥⌘A、Recorderで変更可）
- ツール：v=選択 / d=ペン / t=テキスト / a=矢印 / r=矩形（ツールバーからも選択可）
- 選択ツール：全種類の注釈を選択・移動・8ハンドルでリサイズ、ダブルクリックでテキスト編集
- ツールバー：色/太さ/不透明度/矩形の塗り切替/Undo/全消去
- Undo/Redo：⌘Z / ⌘⇧Z、Delete=選択削除、ESC=選択解除→ペン→非表示

### M1のゴール
ホットキー⌃⌥⌘Aで全ディスプレイに半透明の赤いパネルが出て、
メニューバー/Dock/フルスクリーンアプリの上に被さり、ESCで消える。
Zoomのセルフビューに写ることも確認する。

このプロジェクトのリスクはM1に集中している。
ここが通れば残りは普通のCocoa描画実装になるので、まずM1だけを確実に通すこと。

### セットアップ手順
1. Xcode → New Project → macOS → App（Interface: SwiftUI, Language: Swift）
2. Build Settingsで **Application is agent (UIElement) = YES**
3. SPMで `https://github.com/sindresorhus/KeyboardShortcuts` を追加
4. Signing & Capabilities で **App Sandbox を削除**
5. デフォルト生成の`ContentView.swift`は削除

### 作るファイル
- `OverlayPanel.swift` — `NSPanel`サブクラス。`canBecomeKey = true` / `canBecomeMain = false`。
  `cancelOperation`でESC対応。M1確認用の`OverlayView`（赤く塗るだけ）を同梱
- `OverlayController.swift` — シングルトン。`NSScreen.screens`ごとにパネル生成、
  `didChangeScreenParametersNotification`で再構築。`show()` / `hide()` / `toggle()`
- `ScribbleApp.swift` — `MenuBarExtra` + ホットキー登録 + 設定画面（`KeyboardShortcuts.Recorder`）

パネルの重要な設定（変更しないこと）：
`styleMask: [.borderless, .nonactivatingPanel]` / `level = .screenSaver` /
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` /
`sharingType = .readWrite`

### M1でのつまずきポイント
- フルスクリーンアプリの上に出ない → `.canJoinAllSpaces`と`.fullScreenAuxiliary`は両方必要
- ESCが効かない → `canBecomeKey`のoverride漏れ、または最初の1枚に`makeKeyAndOrderFront`を使っていない
- 画面共有に写らない → `level`を`CGWindowLevelForKey(.overlayWindow)`に下げて再確認

## 設計方針（合意済み・重要）

### 1. 描画はモデルの配列で保持する
ビットマップに焼き込まず、`[Annotation]`を持って毎フレーム描き直す。
これによりテキストの後編集・移動・Undo・高解像度書き出しが全部成立する。
ScreenNoteの弱点はここが「描いたら確定」になっている点なので、最優先で守る。

```swift
enum Annotation {
    case text(TextItem)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor)
    case rect(CGRect, color: NSColor)
}
```

描画は `func draw(_ annotations: [Annotation], in ctx: CGContext, scale: CGFloat)` に一本化し、
画面表示と将来の画像書き出しの両方から呼べる形にする。

### 2. モードは3状態
| 状態 | ignoresMouseEvents | key |
|---|---|---|
| 非表示 | — | — |
| 表示・素通し（描いたものを見せたまま裏のアプリを操作） | true | no |
| 描画中 | false | yes |

画面共有中に裏のアプリを触るたびに全消しする必要をなくすため、素通し状態は必須。

### 3. テキストの扱い（本アプリの主眼）
- ~~バッキングプレート必須~~ → **ユーザー判断で廃止**（背景色は不要とのこと。文字は選択色そのままで描画）
- テキストモード（tキー）でクリック＝横流し入力、ドラッグ＝幅指定ボックス（折り返し）
- 既存テキストはクリックで再編集（キャレットはクリック位置）
- 編集中のみ`NSTextView`を該当座標に載せ、確定時に`TextItem`へ落として自前描画に切り替える二段構え
- サイズ変更：⌘+/⌘-、⌥+スクロール。選択ツールの左右ハンドルは幅のみ変更（フォント維持で折り返し）、角/上下ハンドルはフォント比例

## 次のマイルストーン
- **M2**（完了）：`ignoresMouseEvents`の3状態切り替え。フリーハンド描画
- **M3**（完了）：`[Annotation]`モデル導入 + テキスト（バッキングプレート込み）
- **M4**（完了）：矢印・矩形、Undo、全消去、色/太さのフローティングツールバー（別の小さな`NSPanel`）
- **M5**（完了）：設定の永続化（UserDefaults）、主トリガーのRecorder対応（権限ガイドは不要と判明し撤去）

## 既知の注意点
- Zoom等で「特定ウィンドウの共有」を選ぶとオーバーレイは写らない。運用で「画面全体」に統一する（仕様上の制約）
- Retina：座標系（points）とピクセルの混同に注意。書き出し時は`scale = 2`で再レンダリング
- マルチディスプレイの座標系はY軸が直感に反する。当面はメインディスプレイ優先で割り切る

## 進め方
- 説明は日本語、簡潔に。動くコードを優先
- 大きな変更は一度に出さず、マイルストーン単位で刻む
- 上記の設計方針1〜3から外れる提案をする場合は、理由を明示してから
