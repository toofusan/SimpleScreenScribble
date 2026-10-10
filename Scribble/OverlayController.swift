//
//  OverlayController.swift
//  Scribble
//
//  全ディスプレイのオーバーレイパネルと表示モード、ツールバーを管理するシングルトン。
//

import AppKit

@MainActor
final class OverlayController {
    static let shared = OverlayController()

    /// 3状態（設計方針2）
    enum Mode {
        case hidden        // 非表示
        case passthrough   // 表示・素通し（描いたものを見せたまま裏のアプリを操作）
        case drawing       // 描画中
    }

    private(set) var mode: Mode = .hidden
    private var panels: [OverlayPanel] = []
    private lazy var toolbarPanel = ToolbarPanel()

    private init() {
        // ディスプレイ構成が変わったらパネルを作り直す
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersChanged()
            }
        }

        // ツールバー/キーボードからの状態変更をオーバーレイへ反映
        DrawingState.shared.onToolChange = { [weak self] in
            self?.overlayViews.forEach { $0.handleToolChanged() }
        }
        DrawingState.shared.onAppearanceChange = { [weak self] in
            self?.overlayViews.forEach { $0.applyAppearanceToSelection() }
        }
    }

    // MARK: - Public API

    func toggleVisible() {
        switch mode {
        case .hidden:
            show()
        case .drawing, .passthrough:
            hide()
        }
    }

    func toggleDrawPassthrough() {
        switch mode {
        case .hidden:
            return
        case .drawing:
            setMode(.passthrough)
        case .passthrough:
            setMode(.drawing)
        }
    }

    func show() {
        ensurePanels()
        for panel in panels {
            panel.orderFrontRegardless()
        }
        setMode(.drawing)
    }

    func hide() {
        mode = .hidden
        for panel in panels {
            panel.orderOut(nil)
        }
        toolbarPanel.orderOut(nil)
    }

    // MARK: - Undo / Clear（ツールバー・メニューから）

    func undo() { activeOverlayView?.undo() }
    func redo() { activeOverlayView?.redo() }
    func clearAll() { overlayViews.forEach { $0.clear() } }

    // MARK: - Private

    private var overlayViews: [OverlayView] {
        panels.map(\.overlayView)
    }

    private var activeOverlayView: OverlayView? {
        panels.first(where: { $0.isKeyWindow })?.overlayView ?? panels.first?.overlayView
    }

    private func setMode(_ newMode: Mode) {
        mode = newMode
        applyMode()

        if newMode == .drawing {
            panels.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            toolbarPanel.prepareForShow()
            toolbarPanel.orderFrontRegardless()
        } else {
            // 素通し中は描けないのでツールバーは隠す
            toolbarPanel.orderOut(nil)
        }
    }

    private func applyMode() {
        for panel in panels {
            switch mode {
            case .hidden:
                break
            case .drawing:
                panel.ignoresMouseEvents = false
                panel.overlayView.showsActiveBorder = true
            case .passthrough:
                panel.ignoresMouseEvents = true
                panel.overlayView.showsActiveBorder = false
            }
        }
    }

    private func ensurePanels() {
        if panels.isEmpty {
            panels = NSScreen.screens.map { OverlayPanel(screen: $0) }
        }
    }

    private func screenParametersChanged() {
        let wasVisible = (mode != .hidden)
        let previousMode = mode

        for panel in panels {
            panel.orderOut(nil)
        }
        panels = NSScreen.screens.map { OverlayPanel(screen: $0) }

        guard wasVisible else {
            mode = .hidden
            return
        }
        show()
        if previousMode == .passthrough {
            setMode(.passthrough)
        }
    }
}
