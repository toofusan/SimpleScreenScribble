//
//  HotkeyMonitor.swift
//  Scribble
//
//  修飾キーのみのホットキーをグローバルに検知するモニター。
//  Carbon(RegisterEventHotKey)では修飾キーのみのホットキーを扱えないため、
//  flagsChangedイベントを監視して自前で判定する。
//  flagsChanged（修飾キーの状態変化・文字情報なし）のグローバル監視はTCCの保護対象外で、
//  入力監視/アクセシビリティいずれの権限も不要で動作する（文字キーの監視だけが権限を要する）。
//
//  検知する2つのコード（いずれも押し込んだ瞬間のエッジで1回発火）:
//   - 左右Shift同時押し   → onDoubleShift
//   - Ctrl+Shift 同時押し → onCtrlShift
//

import AppKit

@MainActor
final class HotkeyMonitor {
    // Shiftキーの物理キーコード
    private static let leftShiftKeyCode: UInt16 = 56
    private static let rightShiftKeyCode: UInt16 = 60

    // デバイス依存の修飾フラグ（IOLLEvent.h の NX_DEVICE*SHIFTKEYMASK）
    private static let leftShiftMask: UInt = 0x02
    private static let rightShiftMask: UInt = 0x04

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // 左右Shiftの押下状態
    private var leftShiftDown = false
    private var rightShiftDown = false

    // 各コードのエッジ検出用フラグ
    private var doubleShiftTriggered = false
    private var ctrlShiftTriggered = false

    private let onDoubleShift: () -> Void
    private let onCtrlShift: () -> Void

    init(onDoubleShift: @escaping () -> Void, onCtrlShift: @escaping () -> Void) {
        self.onDoubleShift = onDoubleShift
        self.onCtrlShift = onCtrlShift
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    /// 監視を開始する。flagsChanged監視は無権限で動くため、権限要求は行わない。
    func start() {
        // 他アプリが最前面のとき用
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                self.handle(event)
            }
        }
        // 自アプリ（オーバーレイ）が最前面のとき用。イベントはそのまま流す。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                self.handle(event)
            }
            return event
        }
    }

    // MARK: - Private

    private func handle(_ event: NSEvent) {
        let raw = event.modifierFlags.rawValue

        // 左右Shiftの押下状態を更新
        switch event.keyCode {
        case Self.leftShiftKeyCode:
            leftShiftDown = (raw & Self.leftShiftMask) != 0
        case Self.rightShiftKeyCode:
            rightShiftDown = (raw & Self.rightShiftMask) != 0
        default:
            break
        }

        let bothShift = leftShiftDown && rightShiftDown

        // 左右Shift同時押し（押し込んだ瞬間だけ発火）
        if bothShift {
            if !doubleShiftTriggered {
                doubleShiftTriggered = true
                onDoubleShift()
            }
        } else {
            doubleShiftTriggered = false
        }

        // Ctrl+Shift 同時押し。Cmd/Optが混ざる場合や、左右Shift同時押しとは区別する。
        let flags = event.modifierFlags
        let isCtrlShift =
            flags.contains(.control) &&
            flags.contains(.shift) &&
            !flags.contains(.command) &&
            !flags.contains(.option) &&
            !bothShift
        if isCtrlShift {
            if !ctrlShiftTriggered {
                ctrlShiftTriggered = true
                onCtrlShift()
            }
        } else {
            ctrlShiftTriggered = false
        }
    }

}
