# MacBridge MVP

Dependency-free keyboard/mouse sharing for the topology **Windows above Mac**. Pushing upward past the Mac top edge transfers control; pushing downward past the Windows virtual-desktop bottom edge returns it.

## Install test builds

Download both installers from [GitHub Releases](https://github.com/lornezhang66/macBridgeWin/releases):

- Windows: install `WinBridge-*-windows-x64.msi`, edit `%LocalAppData%\Programs\WinBridge\winbridge.json`, then start WinBridge from the Start menu.
- macOS: install `MacBridge-*-macOS-universal.pkg`, copy and edit the config, then run the client:
  ```sh
  cp /usr/local/share/macbridge/macbridge.example.json ~/macbridge.json
  open -e ~/macbridge.json
  cd ~ && /usr/local/bin/macbridge
  ```

Use the Windows machine's LAN IP and the same long random token in both files. The macOS package is unsigned; use **Control-click → Open** if Gatekeeper warns. Grant macbridge Accessibility access when prompted.

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

Create `macbridge.json` on the Mac. `returnThreshold` documents the paired Windows value and should match it; Windows performs the return-edge decision.

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

1. On Windows, allow inbound TCP port `24800` on the **Private** firewall profile, then start the listener:
   ```powershell
   dotnet run --project windows/WinBridge.csproj -c Release -- --config winbridge.json
   ```
2. On macOS, grant the built `macbridge` executable access in **System Settings → Privacy & Security → Accessibility**. The app prompts on first launch. Then run:
   ```sh
   .build/release/macbridge --config macbridge.json
   ```
3. Put the pointer at the Mac display's top edge and continue pushing upward by `crossingThreshold`. At the Windows virtual-desktop bottom, continue downward by `returnThreshold` to return.

Use Ctrl-C for clean shutdown. Failed authentication never enables injection. Disconnects release injected Windows keys/buttons and restore Mac cursor association and visibility.

## MVP limitations

The JSON-lines TCP connection is authenticated but not encrypted; use it only on a trusted LAN (or tunnel it). One Mac client is served at a time, reconnection is manual, and keyboard mapping targets common US-layout keys. Media keys and IME/layout translation are not included.
