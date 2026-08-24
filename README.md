# MacBridge MVP

MacBridge 用于在 **Windows 显示器位于 MacBook 上方** 的桌面布局中共享键盘和鼠标。

- 鼠标到达 Mac 屏幕顶部后继续向上推动，即可进入 Windows。
- 鼠标到达 Windows 虚拟桌面底部后继续向下推动，即可返回 Mac。

## 下载与安装

请从 [GitHub Releases](https://github.com/lornezhang66/macBridgeWin/releases) 下载两个安装包：

### Windows

1. 安装 `WinBridge-*-windows-x64.msi`。
2. 安装完成后，WinBridge 会自动启动并常驻系统托盘。
3. 双击托盘图标，编辑：
   `%LocalAppData%\Programs\WinBridge\winbridge.json`
4. 将 `token` 从 `change-me` 改为一个较长的随机令牌。
5. 右键托盘图标，选择 **重新启动服务**。
6. Windows 弹出防火墙提示时，只允许其通过 **专用网络**。

托盘菜单可以查看连接状态、编辑配置、重新启动服务、打开安装目录或退出 WinBridge。WinBridge 会在用户登录 Windows 后自动启动。

### macOS

1. 安装 `MacBridge-*-macOS-universal.pkg`。
2. 应用会安装到 `/Applications/MacBridge.app`，安装完成后自动启动。
3. 菜单栏会显示一个键盘图标；首次启动时会出现配置引导。
4. 点击菜单栏图标，选择 **编辑配置…**。
5. 填写 Windows 的局域网 IP，并将 Windows 配置中的同一个 `token` 复制到 Mac 配置。
6. 选择 **重新连接**。
7. 根据系统提示，在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许 MacBridge。

macOS 测试安装包尚未使用 Apple 开发者证书签名。如果系统拦截，请对安装包或应用使用 **按住 Control 键点击 → 打开**。

## 配置说明

### Windows 配置

安装位置：

```text
%LocalAppData%\Programs\WinBridge\winbridge.json
```

示例：

```json
{
  "listenHost": "0.0.0.0",
  "port": 24800,
  "token": "请替换为两台设备相同的长随机令牌",
  "edgeThreshold": 2,
  "returnThreshold": 10
}
```

### macOS 配置

MacBridge 首次启动时会自动创建：

```text
~/Library/Application Support/MacBridge/macbridge.json
```

示例：

```json
{
  "host": "192.168.1.100",
  "port": 24800,
  "token": "请替换为两台设备相同的长随机令牌",
  "pcSide": "top",
  "edgeThreshold": 2,
  "crossingThreshold": 10,
  "returnThreshold": 10,
  "sensitivity": 1.0,
  "scrollScale": 1.0
}
```

参数说明：

- `host`：Windows 电脑的局域网 IP。
- `port`：通信端口，两端必须一致。
- `token`：认证令牌，两端必须完全一致，不能使用 `change-me`。
- `edgeThreshold`：边缘检测范围，单位为像素。
- `crossingThreshold`：从 Mac 进入 Windows 所需的持续向上移动距离。
- `returnThreshold`：从 Windows 返回 Mac 所需的持续向下移动距离。
- `sensitivity`：Windows 鼠标移动倍率。
- `scrollScale`：Windows 滚动倍率。

## 使用方法

1. 确认 Windows 托盘中的 WinBridge 状态为“正在监听”。
2. 确认 Mac 菜单栏中的 MacBridge 状态为“已连接”。
3. 将鼠标移动到 Mac 屏幕顶部，然后继续向上推动超过阈值。
4. 鼠标将从 Windows 虚拟桌面底部对应的横向位置进入。
5. 返回时，将鼠标移动到 Windows 虚拟桌面底部，然后继续向下推动超过阈值。

如果连接失败：

1. 检查两端 `token` 是否完全一致。
2. 检查 Mac 配置中的 Windows IP 是否正确。
3. 检查 Windows 防火墙是否允许 WinBridge 通过专用网络。
4. 确认两台设备位于同一局域网，且 TCP 端口 `24800` 可访问。
5. 修改配置后，在 Windows 选择 **重新启动服务**，在 Mac 选择 **重新连接**。

## 从源码构建与测试

macOS 13 或更高版本，并安装 Xcode Command Line Tools：

```sh
swift test
swift build -c release
```

Windows 安装 .NET 8 SDK：

```powershell
dotnet run --project windows/WinBridge.csproj -- --self-test
dotnet build windows/WinBridge.csproj -c Release
```

## 安全与异常恢复

- 未通过令牌认证时，Windows 不会接受输入注入。
- 连接断开时，Windows 会释放已按下的按键和鼠标按钮。
- 连接断开时，Mac 会恢复本机鼠标和键盘控制。
- 当前 TCP 连接只进行令牌认证，不加密通信。请仅在可信局域网中使用，或通过安全隧道连接。

## 当前限制

- 同一时间只支持一个 Mac 客户端。
- 键盘映射主要面向常见美式键盘按键。
- 暂不支持媒体键、输入法布局转换和完整 IME 映射。
- 当前安装包未进行商业代码签名和 macOS 公证。
