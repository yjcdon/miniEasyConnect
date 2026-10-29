import AppKit
import SwiftUI

// Explicit type alias selects the property wrapper when the CLT SDK also exports a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MainView: View {
    @ObservedObject var controller: ConnectionController
    @ViewState private var connectionIconHovered = false

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(.vertical, 12)
                .frame(height: 216)
            Divider()
            records
        }
        .frame(width: 480, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $controller.showingEditor) {
            if controller.showingEditor {
                ConnectionEditor(controller: controller, profile: controller.editingProfile)
            }
        }
        .sheet(isPresented: Binding(
            get: { controller.snapshot.state == .awaitingChallenge && controller.snapshot.challenge != nil },
            set: { if !$0 && controller.snapshot.state == .awaitingChallenge { controller.disconnect() } }
        )) {
            if controller.snapshot.state == .awaitingChallenge {
                ChallengeView(controller: controller)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private var statusHeader: some View {
        VStack(spacing: 8) {
            Button { controller.toggleConnection() } label: {
                ZStack {
                    Circle().fill(statusColor.opacity(connectionIconHovered && connectionIconEnabled ? 0.18 : 0.10))
                        .frame(width: 76, height: 76)
                    if controller.isBusy && controller.snapshot.state != .awaitingAuthorization {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "network")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundColor(statusColor)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(connectionIconLabel)
            .accessibilityLabel(connectionIconLabel)
            .onHover { connectionIconHovered = $0 }
            .disabled(!connectionIconEnabled)
            Text(controller.stateTitle).font(.system(size: 23, weight: .semibold))
            ZStack {
                Color.clear
                if let description = statusDescription {
                    ScrollView {
                        Text(description)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(width: 370, height: [.failed, .awaitingAuthorization].contains(controller.snapshot.state) ? 32 : 20)
            if [.failed, .awaitingAuthorization].contains(controller.snapshot.state) {
                statusAction
                    .controlSize(.regular)
                    .frame(height: 28)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var statusAction: some View {
        switch controller.snapshot.state {
        case .awaitingAuthorization:
            HStack {
                Button("打开系统设置") { controller.openAuthorizationSettings() }
                Button("已允许，继续连接") { controller.retry() }.buttonStyle(.borderedProminent)
            }
        case .failed:
            HStack {
                if controller.canEditCurrentConnection {
                    Button("修改连接") { controller.editCurrentConnection() }.buttonStyle(.bordered)
                }
                Button("重试连接") { controller.retry() }.buttonStyle(.borderedProminent)
            }
            .disabled(controller.isPerformingCommand)
        case .connected, .connecting, .reconnecting, .awaitingChallenge, .disconnecting, .disconnected:
            EmptyView()
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("连接记录").font(.headline)
                Spacer()
                recordActionButton("新建连接", symbol: "plus") { controller.newConnection() }
                    .padding(.trailing, 12)
            }
            if controller.profiles.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有连接记录").font(.callout)
                    Text("添加连接记录，下次一键连接。")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundColor(.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName).font(.system(.body, design: .rounded)).lineLimit(1)
                    .help(profile.displayName)
                Text("\(profile.serverHost):\(String(profile.serverPort)) · \(profile.username)")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    .help("\(profile.serverHost):\(String(profile.serverPort)) · \(profile.username)")
            }
            Spacer()
            if controller.activeProfile?.id == profile.id && controller.snapshot.state == .connected {
                Text("当前连接").font(.caption).foregroundColor(.green)
            } else {
                Button(controller.snapshot.state == .connected ? "切换" : "连接") {
                    controller.connect(profile)
                }.disabled(!controller.canStartConnection)
            }
            recordActionButton("修改 \(profile.displayName)", symbol: "square.and.pencil") { controller.edit(profile) }
            recordActionButton("删除 \(profile.displayName)", symbol: "trash", destructive: true) { controller.confirmDelete(profile) }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Uses one target size and surface treatment for adding, editing and deleting records.
    private func recordActionButton(_ title: String, symbol: String, destructive: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundColor(destructive ? .white : .primary)
                .background(destructive ? Color.red : Color(nsColor: .controlColor),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!controller.canStartConnection)
        .help(title)
        .accessibilityLabel(title)
    }

    private var connectionIconEnabled: Bool {
        controller.canToggleConnection
    }

    private var connectionIconLabel: String {
        if let target = controller.switchingProfile { return "取消切换：\(target.displayName)" }
        if controller.snapshot.state == .connected {
            return controller.activeProfile.map { "断开：\($0.displayName)" } ?? "断开连接"
        }
        if [.connecting, .reconnecting, .awaitingAuthorization].contains(controller.snapshot.state) {
            return "取消连接"
        }
        if [.disconnected, .failed].contains(controller.snapshot.state) {
            return controller.lastUsedProfile.map { "连接：\($0.displayName)" } ?? "新建连接"
        }
        if let profile = controller.activeProfile {
            return "\(controller.stateTitle)：\(profile.displayName)"
        }
        return controller.stateTitle
    }

    private var statusColor: Color {
        switch controller.snapshot.state {
        case .connected: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }

    private var statusDescription: String? {
        if let target = controller.switchingProfile { return "正在切换至 \(target.displayName)" }
        if let message = controller.snapshot.message, !message.isEmpty { return message }
        if controller.snapshot.state == .connected, let profile = controller.activeProfile {
            return profile.displayName
        }
        return nil
    }
}

private struct ConnectionEditor: View {
    @ObservedObject var controller: ConnectionController
    let profile: ConnectionProfile?
    @ViewState private var address = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var passwordVisible = false
    @ViewState private var note = ""
    @FocusState private var focusedField: ConnectionController.EditorField?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile == nil ? "新建连接" : "修改连接").font(.title2.bold())
            }
            VStack(alignment: .leading, spacing: 14) {
                field("VPN 地址", id: .address) {
                    TextField("", text: $address)
                        .focused($focusedField, equals: .address)
                        .accessibilityLabel("VPN 地址")
                }
                field("账号", id: .username) {
                    TextField("", text: $username)
                        .focused($focusedField, equals: .username)
                        .accessibilityLabel("账号")
                }
                field("密码", id: .password) {
                    HStack(spacing: 8) {
                        Group {
                            if passwordVisible {
                                TextField("", text: $password)
                            } else {
                                SecureField("", text: $password)
                            }
                        }
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("密码")
                        Button {
                            passwordVisible.toggle()
                            focusedField = nil
                            DispatchQueue.main.async { focusedField = .password }
                        } label: {
                            Image(systemName: passwordVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(passwordVisible ? "隐藏密码" : "显示密码")
                        .accessibilityLabel(passwordVisible ? "隐藏密码" : "显示密码")
                    }
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(focusedField == .password ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: focusedField == .password ? 2 : 1)
                    }
                }
                field("备注（可选）", id: .note) {
                    TextField("", text: $note)
                        .focused($focusedField, equals: .note)
                        .accessibilityLabel("备注")
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error = controller.editorError, controller.editorErrorField == nil {
                Text(error).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { controller.showingEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    controller.saveConnection(address: address, username: username, password: password, note: note, replacing: profile)
                    if let field = controller.editorErrorField { focusedField = field }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 420)
        .onAppear {
            if let profile {
                address = profile.serverHost + ":" + String(profile.serverPort)
                username = profile.username
                note = profile.note ?? ""
                do { password = try controller.passwordForEditing(profile) }
                catch {
                    controller.editorError = error.localizedDescription
                    controller.editorErrorField = .password
                }
                focusedField = .password
            } else { focusedField = .address }
        }
        .onChange(of: controller.editorErrorField) { field in
            if let field { focusedField = field }
        }
        .onChange(of: address) { _ in controller.clearEditorError(for: .address) }
        .onChange(of: username) { _ in controller.clearEditorError(for: .username) }
        .onChange(of: password) { _ in controller.clearEditorError(for: .password) }
    }

    private func field<Content: View>(_ title: String, id: ConnectionController.EditorField, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            content()
            if controller.editorErrorField == id, let error = controller.editorError {
                Text(error).font(.callout).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ChallengeView: View {
    @ObservedObject var controller: ConnectionController
    @ViewState private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isCertificate ? "确认服务端证书" : "完成登录验证").font(.title2.bold())
            Text(controller.snapshot.challenge?.message ?? (isCertificate ? "请确认此服务端证书。" : "请输入服务端要求的验证码。"))
                .foregroundColor(.secondary)
            if isCertificate {
                if let fingerprint = controller.snapshot.challenge?.certificateSHA256 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("证书 SHA-256 指纹").font(.caption).foregroundColor(.secondary)
                        Text(fingerprint).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("仅记住此地址的这张证书。证书变更后会再次请你确认。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                if let encoded = controller.snapshot.challenge?.imageBase64,
                   let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 160)
                }
                TextField("验证码", text: $answer).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("验证码")
            }
            HStack {
                Spacer()
                Button("取消连接") { controller.disconnect() }.keyboardShortcut(.cancelAction)
                if isCertificate {
                    Button("信任此证书并连接") { controller.trustCertificate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isPerformingCommand || controller.snapshot.challenge?.certificateSHA256 == nil)
                } else {
                    Button("继续") { controller.answerChallenge(answer); answer = "" }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(answer.isEmpty || controller.isPerformingCommand)
                }
            }
        }
        .padding(26)
        .frame(width: 380)
    }

    private var isCertificate: Bool { controller.snapshot.challenge?.kind == "certificate" }
}
