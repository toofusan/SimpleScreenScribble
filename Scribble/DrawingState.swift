//
//  DrawingState.swift
//  Scribble
//
//  ツール・色・太さ・文字サイズの共有状態。
//  キーボード（d/t/a/r）とフローティングツールバーの両方から操作する。
//

import SwiftUI
import AppKit
import Observation

/// 描画ツールの種類
enum ToolKind: String, CaseIterable, Identifiable {
    case select
    case pen
    case text
    case arrow
    case rect

    var id: Self { self }

    var label: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Draw"
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .rect: return "Rectangle"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        }
    }

    /// キーボードショートカット
    var key: String {
        switch self {
        case .select: return "v"
        case .pen: return "d"
        case .text: return "t"
        case .arrow: return "a"
        case .rect: return "r"
        }
    }
}

@MainActor
@Observable
final class DrawingState {
    static let shared = DrawingState()

    /// UserDefaults のキー
    private enum Key {
        static let tool = "DrawingState.tool"
        static let color = "DrawingState.color"       // [r, g, b, a] の sRGB 成分
        static let lineWidth = "DrawingState.lineWidth"
        static let fontSize = "DrawingState.fontSize"
        static let opacity = "DrawingState.opacity"
        static let rectFilled = "DrawingState.rectFilled"
    }

    private let defaults = UserDefaults.standard

    var tool: ToolKind = .pen {
        didSet {
            defaults.set(tool.rawValue, forKey: Key.tool)
            onToolChange?()
        }
    }
    var color: Color = .red {
        didSet {
            defaults.set(color.rgbaComponents, forKey: Key.color)
            onAppearanceChange?()
        }
    }
    var lineWidth: CGFloat = 4 {
        didSet {
            defaults.set(Double(lineWidth), forKey: Key.lineWidth)
            onAppearanceChange?()
        }
    }
    var fontSize: CGFloat = 24 {
        didSet {
            defaults.set(Double(fontSize), forKey: Key.fontSize)
            onAppearanceChange?()
        }
    }
    /// 不透明度（0.1〜1.0）
    var opacity: Double = 1.0 {
        didSet {
            defaults.set(opacity, forKey: Key.opacity)
            onAppearanceChange?()
        }
    }
    /// 矩形を塗りつぶすか
    var rectFilled: Bool = false {
        didSet {
            defaults.set(rectFilled, forKey: Key.rectFilled)
            onAppearanceChange?()
        }
    }
    /// ツールバーを縦向きにするか（左右端にドックしたとき）
    var isToolbarVertical: Bool = false

    /// ツールが変わったとき（選択解除・カーソル更新など）
    @ObservationIgnored var onToolChange: (() -> Void)?
    /// 色・太さ・サイズが変わったとき（再描画など）
    @ObservationIgnored var onAppearanceChange: (() -> Void)?

    /// 選択中の色（不透明度を適用）
    var nsColor: NSColor { NSColor(color).withAlphaComponent(opacity) }

    // init 内の代入では didSet が呼ばれないため、保存済みの値を安全に復元できる。
    private init() {
        if let raw = defaults.string(forKey: Key.tool), let saved = ToolKind(rawValue: raw) {
            tool = saved
        }
        if let components = defaults.array(forKey: Key.color) as? [Double], components.count == 4 {
            color = Color(rgbaComponents: components)
        }
        if let value = defaults.object(forKey: Key.lineWidth) as? Double {
            lineWidth = CGFloat(value)
        }
        if let value = defaults.object(forKey: Key.fontSize) as? Double {
            fontSize = CGFloat(value)
        }
        if let value = defaults.object(forKey: Key.opacity) as? Double {
            opacity = value
        }
        if defaults.object(forKey: Key.rectFilled) != nil {
            rectFilled = defaults.bool(forKey: Key.rectFilled)
        }
    }
}

// MARK: - Color の永続化（sRGB 成分の配列へ相互変換）

private extension Color {
    var rgbaComponents: [Double] {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.red
        return [Double(ns.redComponent), Double(ns.greenComponent),
                Double(ns.blueComponent), Double(ns.alphaComponent)]
    }

    init(rgbaComponents c: [Double]) {
        self = Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
    }
}
