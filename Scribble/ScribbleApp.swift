//
//  ScribbleApp.swift
//  Scribble
//
//  メニューバー常駐アプリ本体。グローバルホットキーと設定画面を持つ。
//

import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// オーバーレイの表示 / 非表示。主トリガーは左右Shift（HotkeyMonitor）。
    /// こちらは任意のキー組み合わせを割り当てられる補助ホットキー（既定なし）。
    static let toggleVisible = Self("toggleVisible")

    /// 描画 / 素通し 切替。主トリガーは Ctrl+Shift（HotkeyMonitor）。
    /// こちらは Recorder で変更できる補助ホットキー（既定 ⌃⌥⌘A）。
    static let toggleOverlay = Self(
        "toggleOverlay",
        default: .init(.a, modifiers: [.control, .option, .command])
    )
}

@main
struct SimpleScreenScribbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("SimpleScreenScribble", systemImage: "pencil.tip.crop.circle") {
            Button("Show or Hide") {
                OverlayController.shared.toggleVisible()
            }

            Button("Draw or Click Through") {
                OverlayController.shared.toggleDrawPassthrough()
            }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        // 既定の Undo/Redo メニュー項目（⌘Z）を削除する。これが残っていると
        // ⌘Z がメニュー経由で NSUndoManager に渡り、解放済みの編集ビューを
        // 参照してクラッシュする。⌘Z はオーバーレイ側で直接処理する。
        .commands {
            CommandGroup(replacing: .undoRedo) { }
        }

        Settings {
            SettingsView()
        }
    }
}

/// グローバルホットキーの登録をアプリ起動時に行う。
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 修飾キーのみのホットキー監視（アクセシビリティ権限が必要）
    private lazy var hotkeyMonitor = HotkeyMonitor(
        onDoubleShift: { OverlayController.shared.toggleVisible() },      // 左右Shift：表示/非表示
        onCtrlShift: { OverlayController.shared.toggleDrawPassthrough() } // Ctrl+Shift：描画/素通し切替
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyMonitor.start()

        // 補助：Recorderで変更可能な通常ホットキー。
        KeyboardShortcuts.onKeyDown(for: .toggleVisible) {
            OverlayController.shared.toggleVisible()          // 表示 / 非表示
        }
        KeyboardShortcuts.onKeyDown(for: .toggleOverlay) {
            OverlayController.shared.toggleDrawPassthrough()  // 描画 / 素通し 切替（既定 ⌃⌥⌘A）
        }
    }
}

/// 設定画面。ホットキーの再割り当てを持つ。表示文言はやさしい英語で統一。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("Extra Keys") {
                KeyboardShortcuts.Recorder(
                    "Show or hide:",
                    name: .toggleVisible
                )
                KeyboardShortcuts.Recorder(
                    "Draw or click through:",
                    name: .toggleOverlay
                )
                Text("Main keys can't be changed: press both Shift keys to show or hide. Press Control and Shift to turn drawing on or off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}

