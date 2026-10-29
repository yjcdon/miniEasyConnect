import AppKit

/// Owns one native editing sheet and keeps its draft until save succeeds or the user cancels.
@MainActor
final class ConnectionEditorPanel: NSObject, NSTextFieldDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                        styleMask: [.titled], backing: .buffered, defer: true)
    private let controller: ConnectionController
    private let profile: ConnectionProfile?
    private let address = NSTextField()
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let visiblePassword = NSTextField()
    private let passwordBox = NSBox()
    private let note = NSTextField()
    private let eye = NSButton()
    private let saveButton = NSButton()
    private let formError = NSTextField(wrappingLabelWithString: "")
    private let root = NSStackView()
    private var fieldErrors: [ConnectionController.EditorField: NSTextField] = [:]
    private var passwordVisible = false

    init(controller: ConnectionController) {
        self.controller = controller
        profile = controller.editingProfile
        super.init()
        panel.title = profile == nil ? "新建连接" : "修改连接"
        panel.isReleasedWhenClosed = false
        configureContent()
        if let profile {
            address.stringValue = profile.serverHost + ":" + String(profile.serverPort)
            username.stringValue = profile.username
            note.stringValue = profile.note ?? ""
            do { password.stringValue = try controller.passwordForEditing(profile) }
            catch {
                controller.editorError = error.localizedDescription
                controller.editorErrorField = .password
            }
        }
        visiblePassword.stringValue = password.stringValue
        updateError()
        updateSaveButton()
        panel.initialFirstResponder = profile == nil ? address : password
    }

    private var passwordField: NSTextField { passwordVisible ? visiblePassword : password }

    /// Ends the field editor and releases the native sheet hierarchy after its closing animation.
    func releaseContent() {
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func configureContent() {
        guard let content = panel.contentView else { return }
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.detachesHiddenViews = true
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        let title = NSTextField(labelWithString: profile == nil ? "新建连接" : "修改连接")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        root.addArrangedSubview(title)
        for field in [address, username, password, visiblePassword, note] {
            field.delegate = self
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = nil
            field.bezelStyle = .roundedBezel
            field.isBezeled = true
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        addField("VPN 地址", id: .address, input: address)
        addField("账号", id: .username, input: username)
        addField("密码", id: .password, input: passwordInput())
        addField("备注（可选）", id: .note, input: note)
        configureErrorLabel(formError)
        root.addArrangedSubview(formError)
        formError.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        let spacer = NSView()
        footer.addArrangedSubview(spacer)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        footer.addArrangedSubview(cancel)
        saveButton.title = "保存"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        footer.addArrangedSubview(saveButton)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        panel.defaultButtonCell = saveButton.cell as? NSButtonCell
        address.nextKeyView = username
        username.nextKeyView = password
        password.nextKeyView = eye
        visiblePassword.nextKeyView = eye
        eye.nextKeyView = note
        note.nextKeyView = saveButton
        saveButton.nextKeyView = cancel
        cancel.nextKeyView = address
    }

    private func addField(_ title: String, id: ConnectionController.EditorField, input: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let error = NSTextField(wrappingLabelWithString: "")
        configureErrorLabel(error)
        fieldErrors[id] = error
        let row = NSStackView(views: [label, input, error])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.detachesHiddenViews = true
        root.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: root.widthAnchor),
            input.widthAnchor.constraint(equalTo: row.widthAnchor),
            input.heightAnchor.constraint(equalToConstant: 26),
            error.widthAnchor.constraint(equalTo: row.widthAnchor)
        ])
        input.setAccessibilityLabel(title)
    }

    private func configureErrorLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .systemOrange
        label.preferredMaxLayoutWidth = 372
        label.isHidden = true
    }

    private func passwordInput() -> NSView {
        let box = passwordBox
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .textBackgroundColor
        box.cornerRadius = 5
        box.contentViewMargins = NSSize(width: 7, height: 3)
        guard let content = box.contentView else { return box }
        let fields = NSView()
        fields.heightAnchor.constraint(equalToConstant: 20).isActive = true
        for field in [password, visiblePassword] {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.setAccessibilityLabel("密码")
            fields.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: fields.centerYAnchor)
            ])
        }
        visiblePassword.isHidden = true
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密码")
        eye.isBordered = false
        eye.toolTip = "显示密码"
        eye.setAccessibilityLabel("显示密码")
        eye.target = self
        eye.action = #selector(togglePassword)
        eye.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let stack = NSStackView(views: [fields, eye])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return box
    }

    /// Updates error placement without recreating controls or discarding the current draft.
    func updateError(focus: Bool = false) {
        for (field, label) in fieldErrors {
            let message = controller.editorErrorField == field ? controller.editorError : nil
            label.stringValue = message ?? ""
            label.isHidden = message == nil
        }
        let message = controller.editorErrorField == nil ? controller.editorError : nil
        formError.stringValue = message ?? ""
        formError.isHidden = message == nil
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 420, height: root.fittingSize.height + 48))
        if focus, let field = controller.editorErrorField {
            switch field {
            case .address: panel.makeFirstResponder(address)
            case .username: panel.makeFirstResponder(username)
            case .password: panel.makeFirstResponder(passwordField)
            case .note: panel.makeFirstResponder(note)
            }
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, let editor = field.currentEditor() as? NSTextView {
            editor.allowsUndo = true
            if field === password || field === visiblePassword {
                passwordBox.borderColor = .controlAccentColor
                passwordBox.borderWidth = 2
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === password || field === visiblePassword {
            passwordBox.borderColor = .separatorColor
            passwordBox.borderWidth = 1
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            let kind: ConnectionController.EditorField = field === address ? .address : field === username ? .username : field === note ? .note : .password
            controller.clearEditorError(for: kind)
        }
        updateSaveButton()
    }

    private func updateSaveButton() {
        saveButton.isEnabled = !address.stringValue.isEmpty && !username.stringValue.isEmpty && !passwordField.stringValue.isEmpty
    }

    @objc private func togglePassword() {
        let value = passwordField.stringValue
        let selection = (passwordField.currentEditor() as? NSTextView)?.selectedRange()
        passwordVisible.toggle()
        password.stringValue = value
        visiblePassword.stringValue = value
        password.isHidden = passwordVisible
        visiblePassword.isHidden = !passwordVisible
        username.nextKeyView = passwordField
        let label = passwordVisible ? "隐藏密码" : "显示密码"
        eye.image = NSImage(systemSymbolName: passwordVisible ? "eye.slash" : "eye", accessibilityDescription: label)
        eye.toolTip = label
        eye.setAccessibilityLabel(label)
        panel.makeFirstResponder(passwordField)
        if let selection, let editor = passwordField.currentEditor() as? NSTextView { editor.setSelectedRange(selection) }
    }

    @objc private func save() {
        controller.saveConnection(address: address.stringValue, username: username.stringValue,
                                  password: passwordField.stringValue, note: note.stringValue, replacing: profile)
        updateError(focus: true)
    }

    @objc private func cancelEditing() { controller.showingEditor = false }
}
