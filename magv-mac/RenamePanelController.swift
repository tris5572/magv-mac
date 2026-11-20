import AppKit
import MagvCore

/// IMEの変換確定に使うReturnで送信も実行されないよう、専用のフィールドエディターを使う。
@MainActor final class RenameFieldEditor: NSTextView {
    private(set) var isCommittingComposition = false
    override func keyDown(with event: NSEvent) {
        isCommittingComposition = hasMarkedText() && [36, 76].contains(event.keyCode)
        defer { isCommittingComposition = false }
        super.keyDown(with: event)
    }
    static func shouldSubmit(hasMarkedText: Bool, wasComposing: Bool) -> Bool { !hasMarkedText && !wasComposing }
}

/// 拡張子を保持した名前変更パネル。送信中は入力を止め、失敗時は同じパネルで再入力する。
@MainActor final class RenamePanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let contentWidth: CGFloat = 460
    private let padding: CGFloat = 20
    let panel: NSPanel
    private let editor = RenameFieldEditor()
    private let nameField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let submitButton = NSButton(title: "変更", target: nil, action: nil)
    private let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)
    private let stack = NSStackView()
    private let submit: (String, @escaping (Result<Void, Error>) -> Void) -> Void
    private let finished: () -> Void
    private var isPresented = false

    init(source: LoadedSource, previous: String?, next: String?,
         submit: @escaping (String, @escaping (Result<Void, Error>) -> Void) -> Void, finished: @escaping () -> Void) {
        self.submit = submit; self.finished = finished
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 0),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = "名前を変更"; panel.delegate = self; panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        editor.isFieldEditor = true
        nameField.delegate = self; nameField.font = .systemFont(ofSize: 15)
        nameField.cell?.isScrollable = true
        // 既存のファイル名に改行が含まれていても、入力欄は空欄時の1行の高さを使う。
        nameField.heightAnchor.constraint(equalToConstant: nameField.intrinsicContentSize.height).isActive = true
        nameField.stringValue = source.url.deletingPathExtension().lastPathComponent
        nameField.setAccessibilityLabel("アーカイブの名前（拡張子を除く）")
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.setAccessibilityLabel("名前変更のエラー")
        let extensionLabel = NSTextField(labelWithString: "." + source.url.pathExtension)
        let input = NSStackView(views: [nameField, extensionLabel]); input.orientation = .horizontal
        func neighborLabel(_ filename: String, accessibilityLabel: String) -> NSTextField {
            let label = NSTextField(labelWithString: String(filename.map { $0.isNewline ? " " : $0 }))
            label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle
            label.setAccessibilityLabel(accessibilityLabel)
            return label
        }
        submitButton.target = self; submitButton.action = #selector(confirm)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        // Return／Escapeは入力メソッドに渡した後、テキスト入力側で処理する。
        submitButton.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancelButton, submitButton]); buttons.orientation = .horizontal
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let previous { stack.addArrangedSubview(neighborLabel(previous, accessibilityLabel: "前のファイル")) }
        stack.addArrangedSubview(input)
        if let next { stack.addArrangedSubview(neighborLabel(next, accessibilityLabel: "次のファイル")) }
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(buttons)
        let rowWidth = Self.contentWidth - 2 * padding
        errorLabel.preferredMaxLayoutWidth = rowWidth
        NSLayoutConstraint.activate(stack.arrangedSubviews.map { $0.widthAnchor.constraint(equalToConstant: rowWidth) })
        errorLabel.isHidden = true
        let content = panel.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: padding)
        ])
        resizeToFit()
        panel.initialFirstResponder = nameField
    }

    private func resizeToFit() {
        panel.setContentSize(NSSize(width: Self.contentWidth, height: ceil(stack.fittingSize.height) + 2 * padding))
    }

    func present(on window: NSWindow) {
        NSCursor.setHiddenUntilMouseMoves(false)
        var frame = panel.frame
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        panel.setFrame(panel.constrainFrameRect(frame, to: window.screen), display: false)
        isPresented = true
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        nameField.selectText(nil)
        // イベント処理や非同期コールバックから抜けてから、モーダルイベントループを開始する。
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.runModal() }
        }
    }

    private func runModal() {
        guard isPresented else { return }
        NSApp.runModal(for: panel)
        dismiss()
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { client as? NSTextField === nameField ? editor : nil }

    // IMEの変換確定に使ったReturnと、確定済みの入力を送信するReturnを区別する。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard RenameFieldEditor.shouldSubmit(hasMarkedText: textView.hasMarkedText(), wasComposing: editor.isCommittingComposition) else { return true }
            confirm(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() { cancel(); return true }
        return false
    }

    @objc private func confirm() {
        guard submitButton.isEnabled, !editor.hasMarkedText(), !editor.isCommittingComposition else { return }
        // Return時は入力欄への値の反映が間に合わない場合があるため、編集中の文字列を直接取得する。
        let baseName = nameField.currentEditor()?.string ?? nameField.stringValue
        nameField.stringValue = baseName
        setBusy(true); errorLabel.isHidden = true
        resizeToFit()
        submit(baseName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.dismiss()
            case .failure(let error):
                self.setBusy(false); self.errorLabel.stringValue = error.localizedDescription
                self.errorLabel.isHidden = false
                self.resizeToFit()
                self.panel.makeFirstResponder(self.nameField)
                NSAccessibility.post(element: self.errorLabel, notification: .valueChanged)
            }
        }
    }
    private func setBusy(_ busy: Bool) { nameField.isEnabled = !busy; submitButton.isEnabled = !busy; cancelButton.isEnabled = !busy }
    @objc private func cancel() { guard cancelButton.isEnabled else { return }; dismiss() }
    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        if NSApp.modalWindow === panel { NSApp.stopModal() }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil); finished()
    }
}
