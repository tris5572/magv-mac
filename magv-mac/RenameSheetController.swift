import AppKit
import MagvCore

/// The window supplies a field editor so a Return which commits IME text cannot also submit the form.
@MainActor final class RenameFieldEditor: NSTextView {
    private(set) var isCommittingComposition = false
    override func keyDown(with event: NSEvent) {
        isCommittingComposition = hasMarkedText() && [36, 76].contains(event.keyCode)
        defer { isCommittingComposition = false }
        super.keyDown(with: event)
    }
    static func shouldSubmit(hasMarkedText: Bool, wasComposing: Bool) -> Bool { !hasMarkedText && !wasComposing }
}

@MainActor final class RenameSheetController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let panel: NSPanel
    private let editor = RenameFieldEditor()
    private let nameField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let submitButton = NSButton(title: "変更", target: nil, action: nil)
    private let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)
    private let submit: (String, @escaping (Result<Void, Error>) -> Void) -> Void
    private let finished: () -> Void

    init(source: LoadedSource, previous: String?, next: String?,
         submit: @escaping (String, @escaping (Result<Void, Error>) -> Void) -> Void, finished: @escaping () -> Void) {
        self.submit = submit; self.finished = finished
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "名前を変更"; panel.delegate = self; panel.isReleasedWhenClosed = false
        editor.isFieldEditor = true
        nameField.stringValue = source.url.deletingPathExtension().lastPathComponent
        nameField.delegate = self; nameField.font = .systemFont(ofSize: 15)
        nameField.setAccessibilityLabel("アーカイブの名前（拡張子を除く）")
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.setAccessibilityLabel("名前変更のエラー")
        let title = NSTextField(labelWithString: "アーカイブの名前を変更")
        title.font = .boldSystemFont(ofSize: 16)
        let extensionLabel = NSTextField(labelWithString: "." + source.url.pathExtension)
        let input = NSStackView(views: [nameField, extensionLabel]); input.orientation = .horizontal
        let previousLabel = NSTextField(labelWithString: "前: " + (previous ?? "なし"))
        let nextLabel = NSTextField(labelWithString: "次: " + (next ?? "なし"))
        for label in [previousLabel, nextLabel] { label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle }
        submitButton.target = self; submitButton.action = #selector(confirm)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        // Return/Escape are handled by the text input client, after the input method gets them.
        submitButton.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancelButton, submitButton]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, previousLabel, nextLabel, input, errorLabel, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previousLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nextLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func present(on window: NSWindow) {
        NSCursor.setHiddenUntilMouseMoves(false)
        window.beginSheet(panel)
        panel.makeFirstResponder(nameField); nameField.selectText(nil)
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { client as? NSTextField === nameField ? editor : nil }

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
        setBusy(true); errorLabel.stringValue = ""
        submit(nameField.stringValue) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.dismiss()
            case .failure(let error):
                self.setBusy(false); self.errorLabel.stringValue = error.localizedDescription
                self.panel.setContentSize(NSSize(width: 460, height: 300))
                self.panel.makeFirstResponder(self.nameField)
                NSAccessibility.post(element: self.errorLabel, notification: .valueChanged)
            }
        }
    }
    private func setBusy(_ busy: Bool) { nameField.isEnabled = !busy; submitButton.isEnabled = !busy; cancelButton.isEnabled = !busy }
    @objc private func cancel() { guard cancelButton.isEnabled else { return }; dismiss() }
    func dismiss() {
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil); finished()
    }
}
