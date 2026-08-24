# MacBridge MVP

Dependency-free keyboard/mouse sharing for the topology **Windows above Mac**. Pushing upward past the Mac top edge transfers control; pushing downward past the Windows virtual-desktop bottom edge returns it.

## Install test builds

Download both installers from [GitHub Releases](https://github.com/lornezhang66/macBridgeWin/releases):

- Windows: install `WinBridge-*-windows-x64.msi`. WinBridge starts automatically and remains in the system tray. Double-click the tray icon to edit `%LocalAppData%\Programs\WinBridge\winbridge.json`, then choose **重新启动服务** from its right-click menu.
- macOS: install `MacBridge-*-macOS-universal.pkg`. `MacBridge.app` is installed in `/Applications`, starts automatically, and remains visible as a keyboard icon in the menu bar.

From the macOS menu-bar icon, choose **编辑配置…**, enter the Windows LAN IP and copy the same long random token into both configuration files, then choose **重新连接**. Grant Accessibility access when prompted. The package is unsigned; use **Control-click → Open** if Gatekeeper warns.

## Build and test

macOS 13+ with Xcode command-line tools:

```sh
swift test
swift build -c release
```

Windows with .NET 8 SDK (no test packages are used):

```powershell
dotnet run --project windows/WinBridge.csproj -- --self-test
dotnet build windows/WinBridge.csproj -c Release
```

## Configure

Create `winbridge.json` on Windows:

```json
{
  "listenHost": "0.0.0.0",
  "port": 24800,
  "token": "replace-with-the-same-long-random-token",
  "edgeThreshold": 2,
  "returnThreshold": 10
}
```

The installed Mac app creates `~/Library/Application Support/MacBridge/macbridge.json` automatically. Open it from the menu-bar icon. `returnThreshold` documents the paired Windows value and should match it; Windows performs the return-edge decision.

```json
{
  "host": "192.168.1.100",
  "port": 24800,
  "token": "replace-with-the-same-long-random-token",
  "pcSide": "top",
  "edgeThreshold": 2,
  "crossingThreshold": 10,
  "returnThreshold": 10,
  "sensitivity": 1.0,
  "scrollScale": 1.0
}
```

## Run

1. On Windows, allow inbound TCP port `24800` on the **Private** firewall profile. The installed app starts from the system tray; a source build can be started with:
   ```powershell
   dotnet run --project windows/WinBridge.csproj -c Release -- --config winbridge.json
   ```
2. On macOS, open `.build/release/macbridge` for a source build, or `/Applications/MacBridge.app` for an installed build. Grant it access in **System Settings → Privacy & Security → Accessibility** when prompted.
3. Put the pointer at the Mac display's top edge and continue pushing upward by `crossingThreshold`. At the Windows virtual-desktop bottom, continue downward by `returnThreshold` to return.

Use the menu-bar **退出 MacBridge** item (or Ctrl-C for a source build) for clean shutdown. Failed authentication never enables injection. Disconnects release injected Windows keys/buttons and restore Mac cursor association and visibility.

## MVP limitations

The JSON-lines TCP connection is authenticated but not encrypted; use it only on a trusted LAN (or tunnel it). One Mac client is served at a time, reconnection is manual, and keyboard mapping targets common US-layout keys. Media keys and IME/layout translation are not included.
