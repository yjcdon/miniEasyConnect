import AppKit
import SwiftUI

// Explicit type alias selects the property wrapper when the CLT SDK also exports a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MainView: View {
    @ObservedObject var controller: ConnectionController

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(.top, 30)
                .padding(.bottom, 24)
            Divider()
            records
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                Text("密码保存在系统钥匙串")
                Spacer()
                Text("ARM64")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $controller.showingEditor) {
            ConnectionEditor(controller: controller, profile: controller.editingProfile)
        }
        .sheet(isPresented: Binding(
            get: { controller.snapshot.state == .awaitingChallenge && controller.snapshot.challenge != nil },
            set: { if !$0 && controller.snapshot.state == .awaitingChallenge { controller.disconnect() } }
        )) {
            ChallengeView(controller: controller)
        }
        .alert("操作未完成", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private var statusHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor.opacity(0.10)).frame(width: 76, height: 76)
                if controller.isBusy && controller.snapshot.state != .awaitingAuthorization {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: controller.snapshot.state == .connected ? "checkmark.shield.fill" : "network")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(statusColor)
                }
            }
            Text(controller.stateTitle).font(.system(size: 23, weight: .semibold))
            Text(statusDescription)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 370, minHeight: 34)
                .textSelection(.enabled)
            statusAction
                .controlSize(.large)
                .frame(height: 34)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var statusAction: some View {
        switch controller.snapshot.state {
        case .connected:
            Button("断开连接") { controller.disconnect() }
                .buttonStyle(.bordered)
                .disabled(controller.isPerformingCommand)
        case .awaitingAuthorization:
            HStack {
                Button("打开系统设置") { controller.openAuthorizationSettings() }
                Button("已允许，继续连接") { controller.retry() }.buttonStyle(.borderedProminent)
            }
        case .connecting, .reconnecting, .awaitingChallenge:
            Button("取消连接") { controller.disconnect() }.buttonStyle(.bordered)
        case .disconnecting:
            Text("正在恢复网络设置…").font(.callout).foregroundColor(.secondary)
        case .failed:
            Button("重试连接") { controller.retry() }.buttonStyle(.borderedProminent)
        case .disconnected:
            Button("连接") { controller.newConnection() }.buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("连接记录").font(.headline)
                Spacer()
                Button { controller.newConnection() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("新建连接")
                    .accessibilityLabel("新建连接")
                    .disabled(controller.isBusy)
            }
            if controller.profiles.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有连接记录").font(.callout)
                    Text("首次连接成功后自动保存，下次一键连接。")
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
                Text(profile.serverHost).font(.system(.body, design: .rounded)).lineLimit(1)
                Text(profile.username).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if controller.activeProfile?.id == profile.id && controller.snapshot.state == .connected {
                Text("当前连接").font(.caption).foregroundColor(.green)
            } else {
                Button("连接") { controller.connect(profile) }.disabled(controller.isBusy)
            }
            Menu {
                Button("修改") { controller.edit(profile) }
                Button("删除", role: .destructive) { controller.delete(profile) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(controller.isBusy)
            .accessibilityLabel("管理 \(profile.serverHost)")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch controller.snapshot.state {
        case .connected: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }

    private var statusDescription: String {
        if let message = controller.snapshot.message, !message.isEmpty { return message }
        if controller.snapshot.state == .connected, let profile = controller.activeProfile {
            return "\(profile.serverHost)\n现在可以直接访问授权内网。"
        }
        return "连接后即可使用内网，关闭窗口仍保持连接。"
    }
}

private struct ConnectionEditor: View {
    @ObservedObject var controller: ConnectionController
    let profile: ConnectionProfile?
    @ViewState private var address = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @FocusState private var focusedField: Field?
    private enum Field { case address, username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile == nil ? "新建连接" : "修改连接").font(.title2.bold())
                Text("连接成功后保存，下次无需重复输入。")
                    .font(.callout).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                field("VPN 地址") {
                    TextField("vpn.example.com:443", text: $address)
                        .focused($focusedField, equals: .address)
                        .accessibilityLabel("VPN 地址")
                }
                field("账号") {
                    TextField("输入账号", text: $username)
                        .focused($focusedField, equals: .username)
                        .accessibilityLabel("账号")
                }
                field("密码") {
                    SecureField("输入密码", text: $password)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("密码")
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Image(systemName: "lock").foregroundColor(.secondary)
                Text("密码仅保存到这台 Mac 的系统钥匙串。")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            if let error = controller.editorError {
                Text(error).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { controller.showingEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button("连接并保存") {
                    controller.connect(address: address, username: username, password: password, replacing: profile)
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
                do { password = try controller.savedPassword(for: profile) }
                catch { controller.editorError = error.localizedDescription }
                focusedField = .password
            } else { focusedField = .address }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }
}

private struct ChallengeView: View {
    @ObservedObject var controller: ConnectionController
    @ViewState private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完成登录验证").font(.title2.bold())
            Text(controller.snapshot.challenge?.message ?? "请输入服务端要求的验证码。")
                .foregroundColor(.secondary)
            if let encoded = controller.snapshot.challenge?.imageBase64,
               let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 160)
            }
            TextField("验证码", text: $answer).textFieldStyle(.roundedBorder)
                .accessibilityLabel("验证码")
            HStack {
                Spacer()
                Button("取消连接") { controller.disconnect() }.keyboardShortcut(.cancelAction)
                Button("继续") { controller.answerChallenge(answer); answer = "" }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(answer.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 380)
    }
}
