//
//  Annotation.swift
//  Scribble
//
//  注釈のモデルと描画（設計方針1）。
//  ビットマップに焼き込まず [Annotation] を保持し、毎回描き直す。
//  描画は draw(_:in:scale:) に一本化し、画面表示と将来の画像書き出しの両方から呼ぶ。
//

import AppKit

/// レイアウト定数
enum Layout {
    static let textPadding: CGFloat = 4   // テキスト境界の余白（選択枠・ヒット判定用）
}

/// テキスト注釈。origin はテキスト矩形の左上（非フリップ座標＝原点は左下、yは上向き）。
/// maxWidth が nil なら折り返さず横に伸びる（改行は明示的な \n のみ）。
struct TextItem {
    var string: String
    var origin: CGPoint
    var fontSize: CGFloat
    var color: NSColor
    var maxWidth: CGFloat?

    func attributedString() -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
        ])
    }

    func textSize() -> CGSize {
        let constraintWidth = maxWidth ?? .greatestFiniteMagnitude
        let rect = attributedString().boundingRect(
            with: CGSize(width: constraintWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// テキストを囲む矩形（選択枠・ヒット判定に使う）
    func boundingRect() -> CGRect {
        let size = textSize()
        let width = maxWidth ?? size.width
        return CGRect(
            x: origin.x - Layout.textPadding,
            y: origin.y - size.height - Layout.textPadding,
            width: width + Layout.textPadding * 2,
            height: size.height + Layout.textPadding * 2
        )
    }
}

/// 注釈の種類。
enum Annotation {
    case freehand(points: [CGPoint], color: NSColor, width: CGFloat)
    case text(TextItem)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case line(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rect(CGRect, color: NSColor, width: CGFloat, filled: Bool)
}

// MARK: - ジオメトリ（選択・移動・ヒットテスト）

extension Annotation {
    /// 選択枠に使う外接矩形
    var boundingBox: CGRect {
        switch self {
        case let .freehand(points, _, width):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
        case let .text(item):
            return item.boundingRect()
        case let .arrow(from, to, _, width), let .line(from, to, _, width):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
                .insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
        case let .rect(rect, _, width, _):
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    /// 与点がこの注釈に当たるか
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch self {
        case let .freehand(points, _, width):
            let tol = tolerance + width / 2
            for i in 1..<max(points.count, 1) {
                if distanceToSegment(point, points[i - 1], points[i]) <= tol { return true }
            }
            return false
        case let .text(item):
            return item.boundingRect().contains(point)
        case let .arrow(from, to, _, width), let .line(from, to, _, width):
            return distanceToSegment(point, from, to) <= tolerance + width / 2
        case let .rect(rect, _, width, filled):
            if filled { return rect.insetBy(dx: -width / 2, dy: -width / 2).contains(point) }
            // 枠線付近か
            let outer = rect.insetBy(dx: -(tolerance + width / 2), dy: -(tolerance + width / 2))
            let inner = rect.insetBy(dx: tolerance + width / 2, dy: tolerance + width / 2)
            return outer.contains(point) && !inner.contains(point)
        }
    }

    /// 色・太さ・塗りを差し替えた注釈を返す（選択して後から変更する用）
    func withAppearance(color: NSColor, width: CGFloat, filled: Bool) -> Annotation {
        switch self {
        case let .freehand(points, _, _):
            return .freehand(points: points, color: color, width: width)
        case var .text(item):
            item.color = color
            return .text(item)
        case let .arrow(from, to, _, _):
            return .arrow(from: from, to: to, color: color, width: width)
        case let .line(from, to, _, _):
            return .line(from: from, to: to, color: color, width: width)
        case let .rect(rect, _, _, _):
            return .rect(rect, color: color, width: width, filled: filled)
        }
    }

    /// oldBox から newBox へ一律スケールした注釈を返す（複数選択のグループ変形用）
    func scaled(from oldBox: CGRect, to newBox: CGRect) -> Annotation {
        let sx = oldBox.width > 0.5 ? newBox.width / oldBox.width : 1
        let sy = oldBox.height > 0.5 ? newBox.height / oldBox.height : 1
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: newBox.minX + (p.x - oldBox.minX) * sx,
                    y: newBox.minY + (p.y - oldBox.minY) * sy)
        }
        switch self {
        case let .freehand(points, color, width):
            return .freehand(points: points.map(map), color: color, width: width)
        case let .arrow(from, to, color, width):
            return .arrow(from: map(from), to: map(to), color: color, width: width)
        case let .line(from, to, color, width):
            return .line(from: map(from), to: map(to), color: color, width: width)
        case let .rect(rect, color, width, filled):
            let p1 = map(CGPoint(x: rect.minX, y: rect.minY))
            let p2 = map(CGPoint(x: rect.maxX, y: rect.maxY))
            let newRect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                 width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            return .rect(newRect, color: color, width: width, filled: filled)
        case var .text(item):
            let pad = Layout.textPadding
            let topLeft = map(CGPoint(x: item.origin.x - pad, y: item.origin.y + pad))
            item.fontSize = min(max(item.fontSize * sy, 8), 200)
            if let width = item.maxWidth { item.maxWidth = max(width * sx, 10) }
            item.origin = CGPoint(x: topLeft.x + pad, y: topLeft.y - pad)
            return .text(item)
        }
    }

    /// 平行移動
    func translated(by delta: CGSize) -> Annotation {
        switch self {
        case let .freehand(points, color, width):
            return .freehand(points: points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) },
                             color: color, width: width)
        case var .text(item):
            item.origin = CGPoint(x: item.origin.x + delta.width, y: item.origin.y + delta.height)
            return .text(item)
        case let .arrow(from, to, color, width):
            return .arrow(from: CGPoint(x: from.x + delta.width, y: from.y + delta.height),
                          to: CGPoint(x: to.x + delta.width, y: to.y + delta.height),
                          color: color, width: width)
        case let .line(from, to, color, width):
            return .line(from: CGPoint(x: from.x + delta.width, y: from.y + delta.height),
                         to: CGPoint(x: to.x + delta.width, y: to.y + delta.height),
                         color: color, width: width)
        case let .rect(rect, color, width, filled):
            return .rect(rect.offsetBy(dx: delta.width, dy: delta.height), color: color, width: width, filled: filled)
        }
    }
}

/// 点と線分の距離
func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    if dx == 0 && dy == 0 { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
    let projX = a.x + t * dx
    let projY = a.y + t * dy
    return hypot(p.x - projX, p.y - projY)
}

// MARK: - 描画

enum AnnotationRenderer {
    static func draw(_ annotations: [Annotation], in ctx: CGContext, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        for annotation in annotations {
            switch annotation {
            case let .freehand(points, color, width):
                drawFreehand(points, color: color, width: width)
            case let .text(item):
                drawText(item)
            case let .arrow(from, to, color, width):
                drawArrow(from: from, to: to, color: color, width: width)
            case let .line(from, to, color, width):
                drawLine(from: from, to: to, color: color, width: width)
            case let .rect(rect, color, width, filled):
                drawRect(rect, color: color, width: width, filled: filled)
            }
        }

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFreehand(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.stroke()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        color.setStroke()
        color.setFill()

        let angle = atan2(to.y - from.y, to.x - from.x)
        let distance = hypot(to.x - from.x, to.y - from.y)
        // 短い矢印でも破綻しないよう矢じりの大きさを距離で頭打ちにする
        let headLength = min(max(14, width * 3.5), distance * 0.9)
        let headAngle = CGFloat.pi / 7

        // 矢じりの根元（軸線はここで止める。先端まで伸ばすとキャップがはみ出す）
        let base = CGPoint(x: to.x - headLength * cos(angle),
                           y: to.y - headLength * sin(angle))
        let left = CGPoint(x: to.x - headLength * cos(angle - headAngle),
                           y: to.y - headLength * sin(angle - headAngle))
        let right = CGPoint(x: to.x - headLength * cos(angle + headAngle),
                            y: to.y - headLength * sin(angle + headAngle))

        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: base)
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    private static func drawLine(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: from)
        path.line(to: to)
        path.stroke()
    }

    private static func drawRect(_ rect: CGRect, color: NSColor, width: CGFloat, filled: Bool) {
        let path = NSBezierPath(rect: rect)
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private static func drawText(_ item: TextItem) {
        let size = item.textSize()
        let textRect = CGRect(
            x: item.origin.x,
            y: item.origin.y - size.height,
            width: item.maxWidth ?? size.width,
            height: size.height
        )
        item.attributedString().draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
