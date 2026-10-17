//
//  OverlayPanel.swift
//  Scribble
//
//  1ディスプレイを覆う透明パネルと、その上に描くビュー。
//

import AppKit

/// 実画面の上に常駐する透明パネル。
/// 重要な設定（styleMask / level / collectionBehavior / sharingType）は変更しないこと。
final class OverlayPanel: NSPanel {
    let overlayView: OverlayView

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .readWrite

        contentView = overlayView
        initialFirstResponder = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// オーバーレイの描画面。[Annotation] を保持して毎回描き直す（設計方針1）。
final class OverlayView: NSView, NSTextViewDelegate {
    /// バウンディングボックスのハンドル（8点）
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    /// テキストツールのドラッグ
    private enum TextDrag {
        case none
        case newText
    }

    /// 選択ツールのドラッグ
    private enum SelectDrag {
        case none
        case move(start: CGPoint, originals: [Int: Annotation])
        case resize(handle: Handle, originalBox: CGRect, originals: [Int: Annotation])
        case arrowEndpoint(index: Int, movingTo: Bool, original: Annotation)
        case marquee(start: CGPoint)
    }

    // 保持する注釈
    private var annotations: [Annotation] = []

    // Undo / Redo（全体スナップショット方式）
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let undoLimit = 100

    // 選択中の注釈（複数可）
    private var selection: Set<Int> = []
    private var marqueeRect: CGRect?

    // 確定前のプリミティブ
    private var currentStroke: [CGPoint] = []
    private var shapeStart: CGPoint?
    private var shapeCurrent: CGPoint?

    private var downPoint: CGPoint = .zero
    private var suppressStroke = false

    // ドラッグ状態
    private var textDrag: TextDrag = .none
    private var textDragRect: CGRect?
    private var selectDrag: SelectDrag = .none
    private var gestureSnapshot: [Annotation]?
    // 選択オブジェクトへの外観変更（色/不透明度/太さ）のUndoをまとめるためのフラグ
    private var appearanceEditActive = false

    // テキスト編集状態
    private var editor: TextEditorView?
    private var editingOrigin: CGPoint = .zero
    private var editingFixedWidth: CGFloat?
    private var editingOriginalItem: TextItem?
    private var editSnapshot: [Annotation]?

    /// 描画モード中であることを示す枠線を出すか
    var showsActiveBorder = false {
        didSet { needsDisplay = true }
    }

    // 共有状態
    private var tool: ToolKind { DrawingState.shared.tool }
    private var strokeColor: NSColor { DrawingState.shared.nsColor }
    private var strokeWidth: CGFloat { DrawingState.shared.lineWidth }

    private var pad: CGFloat { Layout.textPadding }
    private let handleSize: CGFloat = 12
    private let handleHitSize: CGFloat = 24
    private let hitTolerance: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        if let ctx = NSGraphicsContext.current?.cgContext {
            AnnotationRenderer.draw(annotations, in: ctx, scale: 1)
            if let preview = previewAnnotation() {
                AnnotationRenderer.draw([preview], in: ctx, scale: 1)
            }
        }

        // テキストツールのドラッグ矩形（点線）
        if let rect = textDragRect {
            strokeDashed(rect, color: .systemBlue)
        }

        drawSelection()

        // マーキー選択の矩形
        if let marquee = marqueeRect {
            NSColor.systemBlue.withAlphaComponent(0.1).setFill()
            NSBezierPath(rect: marquee).fill()
            strokeDashed(marquee, color: .systemGray)
        }

        if showsActiveBorder {
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            borderColor.withAlphaComponent(0.6).setStroke()
            border.stroke()
        }
    }

    private func drawSelection() {
        let indices = selection.filter { annotations.indices.contains($0) }
        guard !indices.isEmpty else { return }
        let single = indices.count == 1

        // 個々の選択枠（単一の矢印・直線は端点だけ見せる）
        for index in indices {
            if single, endpoints(of: annotations[index]) != nil { continue }
            strokeDashed(annotations[index].boundingBox, color: .systemBlue)
        }

        if single, let index = indices.first {
            let annotation = annotations[index]
            if let (from, to) = endpoints(of: annotation) {
                drawHandle(at: from)
                drawHandle(at: to)
            } else {
                for handle in Handle.allCases {
                    drawHandle(at: handlePoint(at: handle, in: annotation.boundingBox))
                }
            }
        } else {
            // 複数選択：グループのバウンディングボックス＋8ハンドル
            let group = unionBox(of: indices)
            let path = NSBezierPath(rect: group)
            path.lineWidth = 1.5
            NSColor.systemGreen.setStroke()
            path.stroke()
            for handle in Handle.allCases {
                drawHandle(at: handlePoint(at: handle, in: group))
            }
        }
    }

    private func strokeDashed(_ rect: CGRect, color: NSColor) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    private var borderColor: NSColor {
        switch tool {
        case .text: return .systemBlue
        case .select: return .systemGreen
        default: return strokeColor
        }
    }

    private func previewAnnotation() -> Annotation? {
        switch tool {
        case .pen:
            return currentStroke.count > 1 ? .freehand(points: currentStroke, color: strokeColor, width: strokeWidth) : nil
        case .arrow:
            if let start = shapeStart, let current = shapeCurrent,
               hypot(current.x - start.x, current.y - start.y) > 2 {
                return .arrow(from: start, to: current, color: strokeColor, width: strokeWidth)
            }
            return nil
        case .line:
            if let start = shapeStart, let current = shapeCurrent,
               hypot(current.x - start.x, current.y - start.y) > 2 {
                return .line(from: start, to: current, color: strokeColor, width: strokeWidth)
            }
            return nil
        case .rect:
            if let start = shapeStart, let current = shapeCurrent {
                let rect = rectBetween(start, current)
                if rect.width > 1 || rect.height > 1 {
                    return .rect(rect, color: strokeColor, width: strokeWidth, filled: DrawingState.shared.rectFilled)
                }
            }
            return nil
        case .text, .select:
            return nil
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased()

        if editor == nil, event.modifierFlags.contains(.command), chars == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return
        }

        // ⌘A で全選択（選択ツール）
        if editor == nil, event.modifierFlags.contains(.command), chars == "a", tool == .select {
            selection = Set(annotations.indices)
            needsDisplay = true
            return
        }

        // 選択の削除
        if editor == nil, !selection.isEmpty,
           event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return
        }

        if editor == nil, !event.modifierFlags.contains(.command),
           let selected = ToolKind.allCases.first(where: { $0.key == chars }) {
            DrawingState.shared.tool = selected
            return
        }

        super.keyDown(with: event)
    }

    /// ESC：選択解除 → ペンに戻す → 非表示
    override func cancelOperation(_ sender: Any?) {
        if !selection.isEmpty {
            selection = []
            needsDisplay = true
            return
        }
        if tool != .pen {
            DrawingState.shared.tool = .pen
            return
        }
        OverlayController.shared.hide()
    }

    func handleToolChanged() {
        if editor != nil { endEditing(commit: true) }
        selection = []
        appearanceEditActive = false
        shapeStart = nil
        shapeCurrent = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .text: cursor = .iBeam
        case .select: cursor = .arrow
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        suppressStroke = false

        switch tool {
        case .pen:
            currentStroke = [point]
            needsDisplay = true
        case .arrow, .line, .rect:
            shapeStart = point
            shapeCurrent = point
            needsDisplay = true
        case .text:
            textMouseDown(point)
        case .select:
            selectMouseDown(point, clickCount: event.clickCount,
                            shift: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !suppressStroke else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch tool {
        case .pen:
            currentStroke.append(point)
            needsDisplay = true
        case .arrow, .line, .rect:
            shapeCurrent = point
            needsDisplay = true
        case .text:
            if case .newText = textDrag {
                textDragRect = CGRect(
                    x: min(downPoint.x, point.x), y: min(downPoint.y, point.y),
                    width: abs(point.x - downPoint.x), height: abs(point.y - downPoint.y)
                )
                needsDisplay = true
            }
        case .select:
            selectMouseDragged(point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            suppressStroke = false
            currentStroke = []
            shapeStart = nil
            shapeCurrent = nil
            textDrag = .none
            textDragRect = nil
            selectDrag = .none
            marqueeRect = nil
        }
        if suppressStroke { return }

        let up = convert(event.locationInWindow, from: nil)
        let moved = hypot(up.x - downPoint.x, up.y - downPoint.y) > 4

        switch tool {
        case .pen:
            if moved && currentStroke.count > 1 {
                let stroke = currentStroke
                mutate { annotations.append(.freehand(points: stroke, color: strokeColor, width: strokeWidth)) }
            }
        case .arrow:
            if moved, let start = shapeStart, let current = shapeCurrent {
                mutate { annotations.append(.arrow(from: start, to: current, color: strokeColor, width: strokeWidth)) }
            }
        case .line:
            if moved, let start = shapeStart, let current = shapeCurrent {
                mutate { annotations.append(.line(from: start, to: current, color: strokeColor, width: strokeWidth)) }
            }
        case .rect:
            if moved, let start = shapeStart, let current = shapeCurrent {
                let rect = rectBetween(start, current)
                let filled = DrawingState.shared.rectFilled
                mutate { annotations.append(.rect(rect, color: strokeColor, width: strokeWidth, filled: filled)) }
            }
        case .text:
            textMouseUp(moved: moved)
        case .select:
            selectMouseUp(moved: moved)
        }
    }

    // MARK: - Text tool

    private func textMouseDown(_ point: CGPoint) {
        if editor != nil {
            endEditing(commit: true)
            suppressStroke = true
            return
        }
        if let index = textIndex(at: point) {
            beginEditingExisting(index: index, caretAt: point)
            suppressStroke = true
            return
        }
        textDrag = .newText
        textDragRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    private func textMouseUp(moved: Bool) {
        guard case .newText = textDrag else { return }
        if moved, let rect = textDragRect, rect.width > 8 {
            beginEditingNew(topLeft: CGPoint(x: rect.minX, y: rect.maxY), fixedWidth: rect.width)
        } else {
            beginEditingNew(topLeft: downPoint, fixedWidth: nil)
        }
    }

    // MARK: - Select tool

    private func selectMouseDown(_ point: CGPoint, clickCount: Int, shift: Bool) {
        appearanceEditActive = false

        // テキストをダブルクリック → 編集
        if clickCount >= 2, let index = textIndex(at: point) {
            selection = []
            beginEditingExisting(index: index, caretAt: point)
            suppressStroke = true
            return
        }

        // 既存選択のハンドル → リサイズ / 端点編集
        let indices = selection.filter { annotations.indices.contains($0) }
        if indices.count == 1, let index = indices.first {
            let annotation = annotations[index]
            if let (from, to) = endpoints(of: annotation) {
                if handleContains(center: to, point: point) {
                    gestureSnapshot = annotations
                    selectDrag = .arrowEndpoint(index: index, movingTo: true, original: annotation)
                    return
                }
                if handleContains(center: from, point: point) {
                    gestureSnapshot = annotations
                    selectDrag = .arrowEndpoint(index: index, movingTo: false, original: annotation)
                    return
                }
            } else if let handle = handleHit(box: annotation.boundingBox, point: point) {
                gestureSnapshot = annotations
                selectDrag = .resize(handle: handle, originalBox: annotation.boundingBox, originals: [index: annotation])
                return
            }
        } else if indices.count > 1 {
            let group = unionBox(of: indices)
            if let handle = handleHit(box: group, point: point) {
                gestureSnapshot = annotations
                selectDrag = .resize(handle: handle, originalBox: group, originals: selectedOriginals())
                return
            }
        }

        // オブジェクトにヒット
        if let index = annotationIndex(at: point) {
            if shift {
                if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
                needsDisplay = true
                return
            }
            if !selection.contains(index) { selection = [index] }
            gestureSnapshot = annotations
            selectDrag = .move(start: point, originals: selectedOriginals())
            needsDisplay = true
            return
        }

        // 空き領域 → マーキー選択（Shiftなしなら既存選択を解除）
        if !shift { selection = [] }
        selectDrag = .marquee(start: point)
        marqueeRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    private func selectMouseDragged(_ point: CGPoint) {
        switch selectDrag {
        case let .move(start, originals):
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            for (index, original) in originals {
                annotations[index] = original.translated(by: delta)
            }
            needsDisplay = true

        case let .resize(handle, originalBox, originals):
            let newBox = resizedBox(from: originalBox, handle: handle, to: point)
            let single = originals.count == 1
            for (index, original) in originals {
                annotations[index] = single
                    ? resizeAnnotation(original, handle: handle, from: originalBox, to: newBox)
                    : original.scaled(from: originalBox, to: newBox)
            }
            needsDisplay = true

        case let .arrowEndpoint(index, movingTo, original):
            switch original {
            case let .arrow(from, to, color, width):
                annotations[index] = movingTo
                    ? .arrow(from: from, to: point, color: color, width: width)
                    : .arrow(from: point, to: to, color: color, width: width)
            case let .line(from, to, color, width):
                annotations[index] = movingTo
                    ? .line(from: from, to: point, color: color, width: width)
                    : .line(from: point, to: to, color: color, width: width)
            default:
                break
            }
            needsDisplay = true

        case let .marquee(start):
            marqueeRect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                 width: abs(point.x - start.x), height: abs(point.y - start.y))
            needsDisplay = true

        case .none:
            break
        }
    }

    private func selectMouseUp(moved: Bool) {
        switch selectDrag {
        case .move, .resize, .arrowEndpoint:
            commitGestureUndo(if: moved)
        case .marquee:
            if moved, let marquee = marqueeRect {
                let hits = annotations.indices.filter { annotations[$0].boundingBox.intersects(marquee) }
                selection.formUnion(hits)
                needsDisplay = true
            }
        case .none:
            break
        }
    }

    private func deleteSelection() {
        let indices = selection.sorted(by: >)
        mutate {
            for index in indices where annotations.indices.contains(index) {
                annotations.remove(at: index)
            }
        }
        selection = []
    }

    // MARK: - Scroll（⌥+スクロールでテキストサイズ変更）

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            super.scrollWheel(with: event)
            return
        }
        let delta: CGFloat = event.scrollingDeltaY > 0 ? 2 : (event.scrollingDeltaY < 0 ? -2 : 0)
        guard delta != 0 else { return }

        let point = convert(event.locationInWindow, from: nil)
        if let editor, editor.frame.contains(point) {
            editor.changeFontSize(by: delta)
        } else if let index = textIndex(at: point), case var .text(item) = annotations[index] {
            mutate {
                item.fontSize = clampFontSize(item.fontSize + delta)
                annotations[index] = .text(item)
            }
        }
    }

    // MARK: - Resize logic

    private func resizedBox(from box: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = box.minX, maxX = box.maxX, minY = box.minY, maxY = box.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .left: minX = point.x
        case .right: maxX = point.x
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        }
        let x = min(minX, maxX), y = min(minY, maxY)
        let w = max(abs(maxX - minX), 6), h = max(abs(maxY - minY), 6)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 単一オブジェクトのリサイズ（テキストは幅のみ/フォント比例の使い分け）
    private func resizeAnnotation(_ annotation: Annotation, handle: Handle, from oldBox: CGRect, to newBox: CGRect) -> Annotation {
        switch annotation {
        case var .text(item):
            if handle == .left || handle == .right {
                item.maxWidth = max(newBox.width - pad * 2, 10)
                item.origin = CGPoint(x: newBox.minX + pad, y: newBox.maxY - pad)
            } else {
                let ratio = oldBox.height > 1 ? newBox.height / oldBox.height : 1
                item.fontSize = clampFontSize(item.fontSize * ratio)
                if let width = item.maxWidth {
                    let widthRatio = oldBox.width > 1 ? newBox.width / oldBox.width : 1
                    item.maxWidth = max(width * widthRatio, 10)
                }
                item.origin = CGPoint(x: newBox.minX + pad, y: newBox.maxY - pad)
            }
            return .text(item)
        case let .rect(_, color, width, filled):
            return .rect(newBox.insetBy(dx: width / 2, dy: width / 2), color: color, width: width, filled: filled)
        default:
            return annotation.scaled(from: oldBox, to: newBox)
        }
    }

    // MARK: - Text editing

    private func beginEditingNew(topLeft: CGPoint, fixedWidth: CGFloat?) {
        editSnapshot = annotations
        editingOriginalItem = nil
        editingFixedWidth = fixedWidth
        editingOrigin = CGPoint(x: topLeft.x - pad, y: topLeft.y + pad)
        startEditor(string: "", fontSize: DrawingState.shared.fontSize, caretAt: nil)
    }

    private func beginEditingExisting(index: Int, caretAt caretPoint: CGPoint?) {
        guard case let .text(item) = annotations[index] else { return }
        editSnapshot = annotations
        editingOriginalItem = item
        editingFixedWidth = item.maxWidth
        annotations.remove(at: index)
        selection = []
        editingOrigin = CGPoint(x: item.origin.x - pad, y: item.origin.y + pad)
        startEditor(string: item.string, fontSize: item.fontSize, caretAt: caretPoint)
    }

    private func startEditor(string: String, fontSize: CGFloat, caretAt caretPoint: CGPoint?) {
        let editor = TextEditorView(frame: .zero)
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = strokeColor
        editor.insertionPointColor = strokeColor
        editor.font = NSFont.systemFont(ofSize: fontSize)
        editor.allowsUndo = true
        editor.configureWrapping(fixedWidth: editingFixedWidth, inset: pad)
        editor.string = string
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.endEditing(commit: true) }
        editor.onCancel = { [weak self] in self?.endEditing(commit: false) }
        editor.onFontSizeChange = { [weak self] size in
            DrawingState.shared.fontSize = size
            self?.layoutEditor()
        }

        self.editor = editor
        addSubview(editor)
        layoutEditor()
        window?.makeFirstResponder(editor)

        if let caretPoint {
            let pointInEditor = convert(caretPoint, to: editor)
            let charIndex = editor.characterIndexForInsertion(at: pointInEditor)
            editor.setSelectedRange(NSRange(location: charIndex, length: 0))
        }

        needsDisplay = true
    }

    private func layoutEditor() {
        guard let editor,
              let layoutManager = editor.layoutManager,
              let container = editor.textContainer,
              let font = editor.font else { return }

        let lineHeight = layoutManager.defaultLineHeight(for: font)

        let contentWidth: CGFloat
        if let fixed = editingFixedWidth {
            contentWidth = fixed
        } else {
            layoutManager.ensureLayout(for: container)
            contentWidth = max(ceil(layoutManager.usedRect(for: container).width), ceil(lineHeight))
        }

        editor.frame.size.width = contentWidth + pad * 2 + (editingFixedWidth == nil ? 6 : 0)
        layoutManager.ensureLayout(for: container)
        let contentHeight = max(ceil(layoutManager.usedRect(for: container).height), ceil(lineHeight))
        let height = contentHeight + pad * 2

        editor.frame = CGRect(
            x: editingOrigin.x,
            y: editingOrigin.y - height,
            width: editor.frame.size.width,
            height: height
        )
    }

    private func endEditing(commit: Bool) {
        guard let editor else { return }
        let raw = editor.string
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize = editor.font?.pointSize ?? DrawingState.shared.fontSize

        editor.removeFromSuperview()
        self.editor = nil

        let wasExisting = editingOriginalItem != nil
        var didChange = false

        if commit && !trimmed.isEmpty {
            let item = TextItem(
                string: raw,
                origin: CGPoint(x: editingOrigin.x + pad, y: editingOrigin.y - pad),
                fontSize: fontSize,
                color: strokeColor,
                maxWidth: editingFixedWidth
            )
            annotations.append(.text(item))
            didChange = true
        } else if commit && trimmed.isEmpty && wasExisting {
            didChange = true
        } else if !commit, let original = editingOriginalItem {
            annotations.append(.text(original))
        }

        if didChange, let snapshot = editSnapshot {
            undoStack.append(snapshot)
            trimUndo()
            redoStack.removeAll()
        }

        editSnapshot = nil
        editingOriginalItem = nil
        editingFixedWidth = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Undo / Redo

    private func mutate(_ block: () -> Void) {
        appearanceEditActive = false
        undoStack.append(annotations)
        trimUndo()
        redoStack.removeAll()
        block()
        needsDisplay = true
    }

    private func trimUndo() {
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
    }

    private func commitGestureUndo(if moved: Bool) {
        if moved, let snapshot = gestureSnapshot {
            undoStack.append(snapshot)
            trimUndo()
            redoStack.removeAll()
        }
        gestureSnapshot = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        appearanceEditActive = false
        redoStack.append(annotations)
        annotations = previous
        selection = []
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        appearanceEditActive = false
        undoStack.append(annotations)
        annotations = next
        selection = []
        needsDisplay = true
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        mutate { annotations.removeAll() }
        selection = []
        currentStroke = []
    }

    /// 選択中オブジェクトの色/不透明度/太さ/塗りをツールバーの値に合わせる。
    /// 連続変更（スライダー）は1手のUndoにまとめる。
    func applyAppearanceToSelection() {
        let indices = selection.filter { annotations.indices.contains($0) }
        guard !indices.isEmpty else {
            needsDisplay = true
            return
        }
        if !appearanceEditActive {
            undoStack.append(annotations)
            trimUndo()
            redoStack.removeAll()
            appearanceEditActive = true
        }
        for index in indices {
            annotations[index] = annotations[index].withAppearance(
                color: DrawingState.shared.nsColor,
                width: DrawingState.shared.lineWidth,
                filled: DrawingState.shared.rectFilled
            )
        }
        needsDisplay = true
    }

    // MARK: - Hit testing / geometry

    /// 矢印・直線の2端点（端点ハンドルの共通処理用）。それ以外は nil。
    private func endpoints(of annotation: Annotation) -> (from: CGPoint, to: CGPoint)? {
        switch annotation {
        case let .arrow(from, to, _, _), let .line(from, to, _, _):
            return (from, to)
        default:
            return nil
        }
    }

    private func annotationIndex(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() where annotations[index].hitTest(point, tolerance: hitTolerance) {
            return index
        }
        return nil
    }

    private func textIndex(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() {
            if case let .text(item) = annotations[index], item.boundingRect().contains(point) {
                return index
            }
        }
        return nil
    }

    private func unionBox(of indices: some Sequence<Int>) -> CGRect {
        var result: CGRect?
        for index in indices where annotations.indices.contains(index) {
            let box = annotations[index].boundingBox
            result = result?.union(box) ?? box
        }
        return result ?? .zero
    }

    private func selectedOriginals() -> [Int: Annotation] {
        var originals: [Int: Annotation] = [:]
        for index in selection where annotations.indices.contains(index) {
            originals[index] = annotations[index]
        }
        return originals
    }

    private func handleHit(box: CGRect, point: CGPoint) -> Handle? {
        for handle in Handle.allCases where handleContains(center: handlePoint(at: handle, in: box), point: point) {
            return handle
        }
        return nil
    }

    private func handleContains(center: CGPoint, point: CGPoint) -> Bool {
        CGRect(x: center.x - handleHitSize / 2, y: center.y - handleHitSize / 2,
               width: handleHitSize, height: handleHitSize).contains(point)
    }

    private func drawHandle(at center: CGPoint) {
        let rect = CGRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2,
                          width: handleSize, height: handleSize)
        let path = NSBezierPath(rect: rect)
        NSColor.white.setFill()
        path.fill()
        NSColor.systemBlue.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func handlePoint(at handle: Handle, in box: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: box.minX, y: box.maxY)
        case .top: return CGPoint(x: box.midX, y: box.maxY)
        case .topRight: return CGPoint(x: box.maxX, y: box.maxY)
        case .left: return CGPoint(x: box.minX, y: box.midY)
        case .right: return CGPoint(x: box.maxX, y: box.midY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.minY)
        case .bottom: return CGPoint(x: box.midX, y: box.minY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.minY)
        }
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, 8), 200)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        layoutEditor()
    }
}

/// テキスト編集用の NSTextView。Return確定 / ESCキャンセル / ⌘+・⌘- でサイズ変更。
final class TextEditorView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFontSizeChange: ((CGFloat) -> Void)?

    func configureWrapping(fixedWidth: CGFloat?, inset: CGFloat) {
        let huge = CGFloat.greatestFiniteMagnitude
        textContainerInset = NSSize(width: inset, height: inset)
        isVerticallyResizable = true
        maxSize = NSSize(width: huge, height: huge)

        guard let container = textContainer else { return }
        if let width = fixedWidth {
            isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.size = NSSize(width: width, height: huge)
        } else {
            isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.size = NSSize(width: huge, height: huge)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
        } else {
            onCommit?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                changeFontSize(by: 2)
                return
            case "-":
                changeFontSize(by: -2)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    func changeFontSize(by delta: CGFloat) {
        let current = font?.pointSize ?? 24
        let newSize = min(max(current + delta, 8), 200)
        font = NSFont.systemFont(ofSize: newSize)
        onFontSizeChange?(newSize)
    }
}
