cask "minieasyconnect" do
  version "1.1.0"
  sha256 "3c51ceb029482647dfa431f4587a892f0937faa266a8085e7f91cadf75f430d5"

  url "https://github.com/yjcdon/miniEasyConnect/releases/download/v#{version}/miniEasyConnect-v#{version}-macos-arm64.zip"
  name "miniEasyConnect"
  desc "Native EasyConnect VPN client for Apple Silicon"
  homepage "https://github.com/yjcdon/miniEasyConnect"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "miniEasyConnect.app"

  uninstall quit: "io.github.yjcdon.miniEasyConnect"

  caveats <<~EOS
    This release is development-signed and not notarized by Apple.
    If macOS blocks the first launch, allow it in System Settings > Privacy & Security.
    Before uninstalling, choose "停用后台服务…" in the application's menu.
    Connection records and Keychain passwords are retained when uninstalling.
  EOS
end
