//
//  ToolbarPanel.swift
//  Scribble
//
//  色・太さ・ツール・Undo/全消去のフローティングツールバー（別の小さなNSPanel）。
//  ドラッグで移動でき、左右端に寄せると縦向きになる。
//  描画モードのときだけ表示。overlayより前面・非アクティブでキーを奪わない。
//

import AppKit
import SwiftUI

final class ToolbarPanel: NSPanel, NSWindowDelegate {
    private enum DockEdge {
        case none, left, right
    }

    private var dockEdge: DockEdge = .none
    private let dockMargin: CGFloat = 12
    private let snapZone: CGFloat = 48

    /// ドラッグ中フラグと、離した瞬間を捕まえるためのマウスアップ監視。
    private var isDragging = false
    private var mouseUpMonitors: [Any] = []
    /// プログラム側からの移動（reposition等）でドラッグ判定が誤発火しないよう抑制する。
    private var suppressMoveTracking = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .readWrite

        // ツールバー全体をドラッグ可能に。ボタン/スライダーはAppKitが自動で除外するので
        // 余白部分（背景マテリアル上）をつかむとウィンドウが動く。
        isMovableByWindowBackground = true
        delegate = self

        let host = NSHostingView(rootView: ToolbarView())
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - 表示準備

    /// 表示前に内容へフィットさせ、作業中の画面（カーソルのある画面）へ配置する。
    /// マルチディスプレイで前回別画面に置いたままだと見えないことがあるため、毎回引き寄せる。
    func prepareForShow() {
        resizeToFit()
        reposition(on: Self.activeScreen())
    }

    /// 作業対象の画面：カーソルのある画面を優先、無ければメイン。
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func resizeToFit() {
        guard let host = contentView else { return }
        host.layoutSubtreeIfNeeded()
        setContentSize(host.fittingSize)
    }

    /// 指定画面に合わせて配置する。現在位置がその画面の外なら未配置扱いにして中央下へ戻す。
    private func reposition(on targetScreen: NSScreen?) {
        guard let screen = targetScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = frame.origin
        let onScreen = visible.intersects(frame)

        switch dockEdge {
        case .left:
            origin.x = visible.minX + dockMargin
            origin.y = onScreen ? clampY(origin.y, in: visible) : visible.midY - frame.height / 2
        case .right:
            origin.x = visible.maxX - frame.width - dockMargin
            origin.y = onScreen ? clampY(origin.y, in: visible) : visible.midY - frame.height / 2
        case .none:
            // 中央下（初回・未配置・対象画面外のとき）
            if origin == .zero || !onScreen {
                origin.x = visible.midX - frame.width / 2
                origin.y = visible.minY + 32
            } else {
                origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
                origin.y = clampY(origin.y, in: visible)
            }
        }
        suppressMoveTracking = true
        setFrameOrigin(origin)
        suppressMoveTracking = false
    }

    private func clampY(_ y: CGFloat, in visible: NSRect) -> CGFloat {
        min(max(y, visible.minY), visible.maxY - frame.height)
    }

    // MARK: - ドラッグ中の向き切り替え・終了時のスナップ

    /// ウィンドウ移動通知。`isMovableByWindowBackground`のドラッグ中は連続で呼ばれるので、
    /// ここで向きを切り替え、離した瞬間（マウスアップ）を監視してスナップする。
    func windowDidMove(_ notification: Notification) {
        guard !suppressMoveTracking else { return }
        if !isDragging {
            isDragging = true
            installMouseUpMonitors()
        }
        updateOrientationDuringDrag(mouse: NSEvent.mouseLocation)
    }

    private func installMouseUpMonitors() {
        let end: (NSEvent?) -> Void = { [weak self] _ in self?.endDrag() }
        let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            end(event)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            end(event)
        }
        mouseUpMonitors = [local, global].compactMap { $0 }
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        mouseUpMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseUpMonitors = []
        didFinishDragging(mouse: NSEvent.mouseLocation)
    }

    /// 端に寄っているかをカーソル位置で判定する（幅が変わっても安定するように）。
    private func nearEdge(for mouse: NSPoint) -> DockEdge {
        guard let screen = screen ?? NSScreen.main else { return .none }
        let visible = screen.visibleFrame
        if mouse.x <= visible.minX + snapZone { return .left }
        if mouse.x >= visible.maxX - snapZone { return .right }
        return .none
    }

    /// ドラッグ中に毎フレーム呼ぶ。端に入った瞬間に縦横を切り替える（離す前に反映）。
    func updateOrientationDuringDrag(mouse: NSPoint) {
        let edge = nearEdge(for: mouse)
        let wantVertical = (edge != .none)
        guard DrawingState.shared.isToolbarVertical != wantVertical else { return }
        DrawingState.shared.isToolbarVertical = wantVertical
        // 向き変更のSwiftUI反映を待ってからリサイズ（ドラッグ中は再配置しない）
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    /// ドラッグ終了。最終的な向きを確定し、端にスナップして再配置する。
    func didFinishDragging(mouse: NSPoint) {
        dockEdge = nearEdge(for: mouse)
        let wantVertical = (dockEdge != .none)
        if DrawingState.shared.isToolbarVertical != wantVertical {
            DrawingState.shared.isToolbarVertical = wantVertical
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeToFit()
            // 落とした位置（カーソルのある画面）を基準にスナップする。
            self.reposition(on: Self.activeScreen())
        }
    }
}

/// 標準ツールチップはツールバーパネル（高レベル）の裏に回り込むため、
/// それより更に上のレベルの自前パネルでツールチップを描く。
@MainActor
final class ToolbarTooltip {
    static let shared = ToolbarTooltip()

    private var panel: NSPanel?
    private var pendingShow: DispatchWorkItem?
    private static let showDelay: TimeInterval = 0.5

    private init() {}

    /// ホバー開始：標準同様に少し待ってから表示する。
    func scheduleShow(_ text: String) {
        cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    /// ホバー終了：予約を取り消し、表示中なら隠す。
    func cancel() {
        pendingShow?.cancel()
        pendingShow = nil
        panel?.orderOut(nil)
    }

    private func show(_ text: String) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let hosting = NSHostingView(rootView: TooltipLabel(text: text))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(size)

        // 標準同様、ポインタの右下に出す。画面端は軽くクランプ。
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 14)
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(origin.x, visible.maxX - size.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // ツールバー（screenSaver + 1）より更に上に出す。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readWrite
        return panel
    }
}

/// 標準ツールチップ風の見た目。
private struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .fixedSize()
    }
}

extension View {
    /// `.help` の代わりに、高レベルの自前パネルでツールチップを出す。
    func toolbarTooltip(_ text: String) -> some View {
        onHover { inside in
            if inside {
                ToolbarTooltip.shared.scheduleShow(text)
            } else {
                ToolbarTooltip.shared.cancel()
            }
        }
    }
}

/// ツールバー本体
struct ToolbarView: View {
    @Bindable private var state = DrawingState.shared

    private let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .white, .black]

    private var isVertical: Bool { state.isToolbarVertical }
    private var mainLayout: AnyLayout {
        isVertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }
    private var groupLayout: AnyLayout {
        isVertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
    }

    var body: some View {
        mainLayout {
            // ツール選択
            groupLayout {
                ForEach(ToolKind.allCases) { tool in
                    Button {
                        state.tool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(state.tool == tool ? Color.accentColor.opacity(0.35) : .clear)
                    )
                    .toolbarTooltip("\(tool.label) (\(tool.key.uppercased()))")
                }
            }

            Divider().fixedSize()

            // 色
            groupLayout {
                ForEach(palette, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                state.color == color ? Color.accentColor : Color.gray.opacity(0.5),
                                lineWidth: state.color == color ? 3 : 1
                            )
                        )
                        .onTapGesture { state.color = color }
                }
            }

            Divider().fixedSize()

            // 太さ
            adaptiveSlider($state.lineWidth, in: 1...20, icon: "lineweight")

            // 不透明度
            adaptiveSlider($state.opacity, in: 0.1...1.0, icon: "circle.lefthalf.filled")

            // 矩形の塗り
            Toggle(isOn: $state.rectFilled) {
                Image(systemName: state.rectFilled ? "square.fill" : "square")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .toolbarTooltip("Fill Rectangle")

            Divider().fixedSize()

            // Undo / 全消去
            groupLayout {
                Button {
                    OverlayController.shared.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .toolbarTooltip("Undo (⌘Z)")

                Button {
                    OverlayController.shared.clearAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .toolbarTooltip("Clear All")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .fixedSize()
    }

    /// 太さ・不透明度スライダー。縦レイアウトでは自前の縦スライダーにして幅を詰める。
    @ViewBuilder
    private func adaptiveSlider<V>(_ value: Binding<V>,
                                   in range: ClosedRange<V>,
                                   icon: String) -> some View
    where V: BinaryFloatingPoint, V.Stride: BinaryFloatingPoint {
        if isVertical {
            VStack(spacing: 6) {
                Image(systemName: icon)
                VerticalSlider(value: value, range: range)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Slider(value: value, in: range)
                    .frame(width: 70)
            }
        }
    }
}

/// SwiftUIのDragGesture製ビューは`isMovableByWindowBackground`にドラッグを奪われるため、
/// 縦スライダーは実AppKitの`NSSlider`（vertical）を使う。これなら当たり判定が正しく、幅も狭い。
struct VerticalSlider<V>: View where V: BinaryFloatingPoint, V.Stride: BinaryFloatingPoint {
    @Binding var value: V
    let range: ClosedRange<V>
    var height: CGFloat = 64

    var body: some View {
        NSSliderRepresentable(
            value: Binding(
                get: { Double(value) },
                set: { value = V($0) }
            ),
            range: Double(range.lowerBound)...Double(range.upperBound)
        )
        .frame(width: 18, height: height)
    }
}

/// 縦向きNSSliderのSwiftUIブリッジ。
private struct NSSliderRepresentable: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value,
                              minValue: range.lowerBound,
                              maxValue: range.upperBound,
                              target: context.coordinator,
                              action: #selector(Coordinator.valueChanged(_:)))
        slider.isVertical = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.value = $value
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        if nsView.doubleValue != value { nsView.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func valueChanged(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
    }
}
