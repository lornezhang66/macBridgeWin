using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--self-test")) return SelfTests.Run();
        if (!OperatingSystem.IsWindows()) return 1;

        using var singleInstance = new Mutex(true, "Local\\MacBridge.WinBridge", out var created);
        if (!created) return 0;

        var path = ValueAfter(args, "--config") ?? Path.Combine(AppContext.BaseDirectory, "winbridge.json");
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext(path));
        return 0;
    }

    private static string? ValueAfter(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
}

internal sealed class TrayContext : ApplicationContext
{
    private readonly string _configPath;
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _status = new("正在启动…") { Enabled = false };
    private readonly ToolStripMenuItem _restart = new("重新启动服务");
    private CancellationTokenSource? _serverStop;
    private Task? _serverTask;
    private bool _restarting;
    private bool _firstStart = true;

    public TrayContext(string configPath)
    {
        _configPath = configPath;
        var menu = new ContextMenuStrip();
        menu.Items.Add(_status);
        menu.Items.Add(new ToolStripSeparator());
        _restart.Click += (_, _) => StartServer();
        menu.Items.Add(_restart);
        menu.Items.Add("编辑配置…", null, (_, _) => OpenConfig());
        menu.Items.Add("打开安装目录…", null, (_, _) => OpenInstallFolder());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出 WinBridge", null, (_, _) => ExitThread());

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "WinBridge",
            ContextMenuStrip = menu,
            Visible = true
        };
        _icon.DoubleClick += (_, _) => OpenConfig();
        StartServer();
    }

    protected override void ExitThreadCore()
    {
        _serverStop?.Cancel();
        _icon.Visible = false;
        _icon.Dispose();
        base.ExitThreadCore();
    }

    private async void StartServer()
    {
        if (_restarting) return;
        _restarting = true;
        _restart.Enabled = false;
        var oldStop = _serverStop;
        var oldTask = _serverTask;
        _serverStop = null;
        _serverTask = null;
        oldStop?.Cancel();
        if (oldTask is not null)
        {
            try { await oldTask; }
            catch { }
        }
        oldStop?.Dispose();

        try
        {
            var config = JsonSerializer.Deserialize<BridgeConfig>(await File.ReadAllTextAsync(_configPath), Json.Options)
                         ?? throw new InvalidDataException("配置为空");
            config.Validate();
            var stop = new CancellationTokenSource();
            var task = Task.Run(() => new BridgeServer(config, SetStatus).RunAsync(stop.Token));
            _serverStop = stop;
            _serverTask = task;
            _ = ObserveServerAsync(task, stop);
        }
        catch (Exception ex)
        {
            SetStatus($"未运行：{ex.Message}");
            if (_firstStart)
            {
                _icon.ShowBalloonTip(8000, "WinBridge 需要配置",
                    "双击托盘图标填写令牌，然后选择“重新启动服务”。", ToolTipIcon.Info);
                OpenConfig();
            }
        }
        finally
        {
            _firstStart = false;
            _restart.Enabled = true;
            _restarting = false;
        }
    }

    private async Task ObserveServerAsync(Task task, CancellationTokenSource stop)
    {
        try { await task; }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception ex)
        {
            if (ReferenceEquals(_serverStop, stop)) SetStatus($"服务已停止：{ex.Message}");
        }
    }

    private void SetStatus(string text)
    {
        if (_status.Owner?.InvokeRequired == true)
        {
            _status.Owner.BeginInvoke(new Action(() => SetStatus(text)));
            return;
        }
        _status.Text = text;
        _icon.Text = text.Length <= 63 ? text : text[..63];
    }

    private void OpenConfig()
    {
        if (!File.Exists(_configPath)) File.WriteAllText(_configPath, "{}\n");
        Process.Start(new ProcessStartInfo("notepad.exe", $"\"{_configPath}\"") { UseShellExecute = true });
    }

    private static void OpenInstallFolder() =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{AppContext.BaseDirectory}\"") { UseShellExecute = true });
}

internal sealed record BridgeConfig
{
    public string ListenHost { get; init; } = "0.0.0.0";
    public int Port { get; init; } = 24800;
    public string Token { get; init; } = "change-me";
    public double EdgeThreshold { get; init; } = 2;
    public double ReturnThreshold { get; init; } = 10;

    public void Validate()
    {
        if (!IPAddress.TryParse(ListenHost, out _)) throw new InvalidDataException("listenHost 必须是 IP 地址");
        if (Port is < 1 or > 65535) throw new InvalidDataException("port 必须在 1 到 65535 之间");
        if (string.IsNullOrEmpty(Token) || Token == "change-me") throw new InvalidDataException("请设置非默认 token");
        if (!double.IsFinite(EdgeThreshold) || !double.IsFinite(ReturnThreshold) ||
            EdgeThreshold is < 0 or > 100 || ReturnThreshold is < 1 or > 1_000)
            throw new InvalidDataException("阈值超出允许范围");
    }
}

internal sealed class BridgeServer(BridgeConfig config, Action<string>? report = null)
{
    private readonly TcpListener _listener = new(IPAddress.Parse(config.ListenHost), config.Port);

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        _listener.Start();
        report?.Invoke($"正在监听 {config.ListenHost}:{config.Port}");
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                using var client = await _listener.AcceptTcpClientAsync(cancellationToken);
                client.NoDelay = true;
                client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                try { await ServeAsync(client, cancellationToken); }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    report?.Invoke("客户端认证超时，继续等待连接");
                }
                catch (Exception ex) when ((ex is IOException or SocketException or InvalidDataException or JsonException or TimeoutException) &&
                                             !cancellationToken.IsCancellationRequested)
                {
                    report?.Invoke($"连接中断：{ex.Message}");
                }
            }
        }
        finally { _listener.Stop(); }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken cancellationToken)
    {
        var input = new WindowsInput(config);
        var stream = client.GetStream();
        var reader = new JsonLineReader(stream);
        report?.Invoke($"Mac 已连接：{client.Client.RemoteEndPoint}");
        try
        {
            using var authTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            authTimeout.CancelAfter(TimeSpan.FromSeconds(5));
            var authLine = await reader.ReadLineAsync(authTimeout.Token);
            if (authLine is null || !Protocol.Authenticates(authLine, config.Token))
            {
                await Json.WriteAsync(stream, new { type = "auth_failed" }, cancellationToken);
                report?.Invoke("认证失败");
                return;
            }
            await Json.WriteAsync(stream, new { type = "auth_ok" }, cancellationToken);
            report?.Invoke("Mac 已连接并通过认证");

            while (await reader.ReadLineAsync(cancellationToken)
                               .WaitAsync(TimeSpan.FromSeconds(8), cancellationToken) is { } line)
            {
                try
                {
                    using var document = JsonDocument.Parse(line);
                    var reply = input.Handle(document.RootElement);
                    if (reply is not null) await Json.WriteAsync(stream, reply, cancellationToken);
                }
                catch (JsonException) { /* Ignore malformed authenticated messages. */ }
            }
        }
        finally
        {
            input.ReleaseAll();
            report?.Invoke("Mac 已断开，等待连接");
        }
    }
}

internal static class Protocol
{
    public static bool Authenticates(string json, string expectedToken)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String ||
                type.GetString() != "auth" ||
                !root.TryGetProperty("token", out var token) || token.ValueKind != JsonValueKind.String) return false;
            var supplied = Encoding.UTF8.GetBytes(token.GetString()!);
            var expected = Encoding.UTF8.GetBytes(expectedToken);
            return supplied.Length == expected.Length && CryptographicOperations.FixedTimeEquals(supplied, expected);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException) { return false; }
    }
}

internal sealed class WindowsInput
{
    private readonly BridgeConfig _config;
    private readonly ReturnAccumulator _returning;
    private readonly HashSet<ushort> _keys = [];
    private readonly HashSet<string> _buttons = [];
    private readonly FractionalDelta _moveX = new(), _moveY = new(), _scrollX = new(), _scrollY = new();
    private bool _active;

    public WindowsInput(BridgeConfig config)
    {
        _config = config;
        _returning = new ReturnAccumulator(config.ReturnThreshold);
    }

    public object? Handle(JsonElement message)
    {
        if (message.ValueKind != JsonValueKind.Object ||
            !message.TryGetProperty("type", out var typeProperty) || typeProperty.ValueKind != JsonValueKind.String)
            return null;
        var type = typeProperty.GetString();
        if (type == "enter_pc" && Number(message, "xRatio") is { } ratio)
        {
            ReleaseAll();
            var desktop = Native.Desktop();
            if (desktop.Width <= 0 || desktop.Height <= 0) return null;
            Native.SetCursorPos(Ratio.MapToPixel(ratio, desktop.Left, desktop.Width), desktop.Bottom - 2);
            _active = true;
            _returning.Reset();
            return null;
        }
        if (!_active) return null;

        switch (type)
        {
            case "move" when Number(message, "dx") is { } dx && Number(message, "dy") is { } dy:
                var moveX = _moveX.Take(dx);
                var moveY = _moveY.Take(dy);
                if (moveX != 0 || moveY != 0) Native.MouseMove(moveX, moveY);
                if (Native.GetCursorPos(out var point))
                {
                    var desktop = Native.Desktop();
                    var atBottom = desktop.Width > 0 && desktop.Height > 0 &&
                        point.Y >= desktop.Bottom - _config.EdgeThreshold;
                    if (_returning.Update(atBottom, Math.Clamp(dy, -100_000, 100_000),
                                          Environment.TickCount64 / 1000.0))
                    {
                        var xRatio = Ratio.FromPosition(point.X, desktop.Left, desktop.Width);
                        ReleaseAll();
                        _active = false;
                        return new { type = "return_mac", xRatio };
                    }
                }
                break;
            case "mouse_down" when Text(message, "button") is { } downButton:
                if (Native.MouseButton(downButton, true)) _buttons.Add(downButton);
                break;
            case "mouse_up" when Text(message, "button") is { } upButton:
                if (Native.MouseButton(upButton, false)) _buttons.Remove(upButton);
                break;
            case "scroll":
                Native.Scroll(_scrollX.Take(Number(message, "dx") ?? 0),
                              _scrollY.Take(Number(message, "dy") ?? 0));
                break;
            case "key_down" when Text(message, "key") is { } downKey && Native.TryVirtualKey(downKey, out var downVk):
                Native.Key(downVk, true);
                _keys.Add(downVk);
                break;
            case "key_up" when Text(message, "key") is { } upKey && Native.TryVirtualKey(upKey, out var upVk):
                Native.Key(upVk, false);
                _keys.Remove(upVk);
                break;
        }
        return null;
    }

    public void ReleaseAll()
    {
        foreach (var key in _keys) Native.Key(key, false);
        foreach (var button in _buttons) Native.MouseButton(button, false);
        _keys.Clear();
        _buttons.Clear();
        _moveX.Reset();
        _moveY.Reset();
        _scrollX.Reset();
        _scrollY.Reset();
        _returning.Reset();
    }

    private static double? Number(JsonElement root, string name) =>
        root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number)
            ? number : null;

    private static string? Text(JsonElement root, string name) =>
        root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String ? value.GetString() : null;

}

internal sealed class FractionalDelta
{
    private double _remainder;

    public int Take(double value)
    {
        if (!double.IsFinite(value)) { Reset(); return 0; }
        var total = _remainder + Math.Clamp(value, -100_000, 100_000);
        var whole = Math.Truncate(total);
        _remainder = total - whole;
        return (int)whole;
    }

    public void Reset() => _remainder = 0;
}

internal sealed class ReturnAccumulator(double threshold, double idleResetSeconds = 0.5)
{
    private double _total;
    private double? _lastUpdate;
    public double Total => _total;

    public bool Update(bool atEdge, double downwardDelta, double now)
    {
        if (!double.IsFinite(threshold) || threshold <= 0 || !double.IsFinite(idleResetSeconds) ||
            idleResetSeconds < 0 || !double.IsFinite(downwardDelta) || !double.IsFinite(now))
        {
            Reset();
            return false;
        }
        if (!atEdge || downwardDelta <= 0 ||
            (_lastUpdate is { } last && (now < last || now - last > idleResetSeconds))) _total = 0;
        if (!atEdge || downwardDelta <= 0)
        {
            _lastUpdate = null;
            return false;
        }
        _total = Math.Min(threshold, _total + downwardDelta);
        _lastUpdate = now;
        if (_total < threshold) return false;
        Reset();
        return true;
    }

    public void Reset() { _total = 0; _lastUpdate = null; }
}

internal static class Ratio
{
    public static double FromPosition(double position, double origin, double length) =>
        !double.IsFinite(position) || !double.IsFinite(origin) || !double.IsFinite(length) || length <= 0
            ? 0 : Math.Clamp((position - origin) / length, 0, 1);

    public static int MapToPixel(double ratio, int origin, int length)
    {
        if (!double.IsFinite(ratio) || length <= 0) return origin;
        var mapped = origin + (double)length * Math.Clamp(ratio, 0, 1);
        return (int)Math.Clamp(Math.Round(mapped), origin, origin + (double)length - 1);
    }
}

internal sealed class JsonLineReader(NetworkStream stream)
{
    private readonly byte[] _buffer = new byte[8_192];
    private int _offset;
    private int _count;

    public async Task<string?> ReadLineAsync(CancellationToken cancellationToken)
    {
        using var line = new MemoryStream();
        while (true)
        {
            if (_offset < _count)
            {
                var newline = Array.IndexOf(_buffer, (byte)'\n', _offset, _count - _offset);
                var end = newline >= 0 ? newline : _count;
                var length = end - _offset;
                if (line.Length + length > 65_536) throw new InvalidDataException("协议行超过 65536 字节");
                line.Write(_buffer, _offset, length);
                _offset = newline >= 0 ? newline + 1 : _count;
                if (newline >= 0)
                {
                    var data = line.ToArray();
                    var size = data.Length > 0 && data[^1] == (byte)'\r' ? data.Length - 1 : data.Length;
                    return Encoding.UTF8.GetString(data, 0, size);
                }
            }

            _count = await stream.ReadAsync(_buffer, cancellationToken);
            _offset = 0;
            if (_count == 0)
                return line.Length == 0 ? null : Encoding.UTF8.GetString(line.ToArray());
        }
    }
}

internal static class Json
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    public static async Task WriteAsync(NetworkStream stream, object value, CancellationToken cancellationToken)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(value);
        await stream.WriteAsync(data, cancellationToken);
        await stream.WriteAsync(new byte[] { (byte)'\n' }, cancellationToken);
    }
}

internal static class Native
{
    private const uint InputMouse = 0, InputKeyboard = 1;
    private const uint MouseMoveFlag = 0x0001, LeftDown = 0x0002, LeftUp = 0x0004,
        RightDown = 0x0008, RightUp = 0x0010, MiddleDown = 0x0020, MiddleUp = 0x0040,
        Wheel = 0x0800, HWheel = 0x1000, KeyUp = 0x0002;

    public static (int Left, int Top, int Width, int Height, int Bottom) Desktop()
    {
        var left = GetSystemMetrics(76);
        var top = GetSystemMetrics(77);
        var width = GetSystemMetrics(78);
        var height = GetSystemMetrics(79);
        return (left, top, width, height, top + height);
    }

    public static void MouseMove(int dx, int dy) => SendMouse(dx, dy, 0, MouseMoveFlag);

    public static bool MouseButton(string button, bool down)
    {
        var flag = (button, down) switch
        {
            ("left", true) => LeftDown, ("left", false) => LeftUp,
            ("right", true) => RightDown, ("right", false) => RightUp,
            ("middle", true) => MiddleDown, ("middle", false) => MiddleUp,
            _ => 0u
        };
        if (flag == 0) return false;
        SendMouse(0, 0, 0, flag);
        return true;
    }

    public static void Scroll(int dx, int dy)
    {
        if (dy != 0) SendMouse(0, 0, unchecked((uint)dy), Wheel);
        if (dx != 0) SendMouse(0, 0, unchecked((uint)dx), HWheel);
    }

    public static void Key(ushort virtualKey, bool down)
    {
        var input = new INPUT
        {
            Type = InputKeyboard,
            Union = new InputUnion { Keyboard = new KEYBDINPUT { VirtualKey = virtualKey, Flags = down ? 0 : KeyUp } }
        };
        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    public static bool TryVirtualKey(string key, out ushort value)
    {
        if (key.Length == 1)
        {
            var character = char.ToUpperInvariant(key[0]);
            if (character is >= 'A' and <= 'Z' or >= '0' and <= '9') { value = character; return true; }
        }
        return Keys.TryGetValue(key, out value);
    }

    private static void SendMouse(int dx, int dy, uint data, uint flags)
    {
        var input = new INPUT
        {
            Type = InputMouse,
            Union = new InputUnion { Mouse = new MOUSEINPUT { Dx = dx, Dy = dy, MouseData = data, Flags = flags } }
        };
        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    private static readonly Dictionary<string, ushort> Keys = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ENTER"]=0x0D, ["TAB"]=0x09, ["SPACE"]=0x20, ["BACKSPACE"]=0x08, ["ESCAPE"]=0x1B,
        ["LSHIFT"]=0xA0, ["RSHIFT"]=0xA1, ["LCONTROL"]=0xA2, ["RCONTROL"]=0xA3,
        ["LALT"]=0xA4, ["RALT"]=0xA5, ["LWIN"]=0x5B, ["RWIN"]=0x5C, ["CAPSLOCK"]=0x14,
        ["LEFT"]=0x25, ["UP"]=0x26, ["RIGHT"]=0x27, ["DOWN"]=0x28, ["HOME"]=0x24,
        ["END"]=0x23, ["PAGEUP"]=0x21, ["PAGEDOWN"]=0x22, ["INSERT"]=0x2D, ["DELETE"]=0x2E,
        ["F1"]=0x70, ["F2"]=0x71, ["F3"]=0x72, ["F4"]=0x73, ["F5"]=0x74, ["F6"]=0x75,
        ["F7"]=0x76, ["F8"]=0x77, ["F9"]=0x78, ["F10"]=0x79, ["F11"]=0x7A, ["F12"]=0x7B,
        ["F13"]=0x7C, ["F14"]=0x7D, ["F15"]=0x7E, ["F16"]=0x7F, ["F17"]=0x80,
        ["F18"]=0x81, ["F19"]=0x82, ["NUMLOCK"]=0x90, ["NUM0"]=0x60, ["NUM1"]=0x61,
        ["NUM2"]=0x62, ["NUM3"]=0x63, ["NUM4"]=0x64, ["NUM5"]=0x65, ["NUM6"]=0x66,
        ["NUM7"]=0x67, ["NUM8"]=0x68, ["NUM9"]=0x69, ["MULTIPLY"]=0x6A, ["ADD"]=0x6B,
        ["SUBTRACT"]=0x6D, ["DECIMAL"]=0x6E, ["DIVIDE"]=0x6F, ["NUMENTER"]=0x0D,
        ["`"]=0xC0, ["-"]=0xBD, ["="]=0xBB, ["["]=0xDB, ["]"]=0xDD, ["\\"]=0xDC,
        [";"]=0xBA, ["'"]=0xDE, [","]=0xBC, ["."]=0xBE, ["/"]=0xBF
    };

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint Type; public InputUnion Union; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT
    { public int Dx, Dy; public uint MouseData, Flags, Time; public UIntPtr ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT
    { public ushort VirtualKey, Scan; public uint Flags, Time; public UIntPtr ExtraInfo; }

    [DllImport("user32.dll")] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
}

internal static class SelfTests
{
    public static int Run()
    {
        try
        {
            var crossing = new ReturnAccumulator(10);
            Assert(!crossing.Update(true, 4, 1), "threshold step 1");
            Assert(!crossing.Update(true, 5, 1.1), "threshold step 2");
            Assert(crossing.Update(true, 1, 1.2), "threshold crossing");
            Assert(!crossing.Update(true, 6, 2), "new intent");
            Assert(!crossing.Update(true, -1, 2.1), "reverse resets");
            Assert(!crossing.Update(true, 4, 3), "pause resets");
            Assert(crossing.Total == 4, "post-pause total");
            Assert(!crossing.Update(true, double.NaN, 3.1) && crossing.Total == 0, "invalid delta resets");
            Assert(!crossing.Update(true, 6, 4), "clock baseline");
            Assert(!crossing.Update(true, 6, 3.9) && crossing.Total == 6, "backward clock resets");
            Assert(Ratio.FromPosition(-960, -1920, 1920) == 0.5, "virtual desktop ratio");
            Assert(Ratio.MapToPixel(2, -1920, 1920) == -1, "ratio clamp");
            Assert(Ratio.FromPosition(double.NaN, 0, 100) == 0, "invalid ratio input");
            var fractional = new FractionalDelta();
            Assert(fractional.Take(0.5) == 0 && fractional.Take(0.5) == 1, "fractional motion accumulates");
            Assert(fractional.Take(-0.25) == 0 && fractional.Take(-0.75) == -1, "negative fraction accumulates");
            Assert(Protocol.Authenticates("{\"type\":\"auth\",\"token\":\"secret\"}", "secret"), "auth accepts token");
            Assert(!Protocol.Authenticates("{\"type\":\"move\",\"token\":\"secret\"}", "secret"), "input cannot authenticate");
            Assert(!Protocol.Authenticates("{\"type\":\"auth\",\"token\":\"wrong\"}", "secret"), "auth rejects token");
            Assert(!Protocol.Authenticates("{\"type\":1,\"token\":\"secret\"}", "secret"), "auth rejects wrong JSON kinds");
            RunServerResilienceAsync().GetAwaiter().GetResult();
            Console.WriteLine("winbridge self-tests: passed");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"winbridge self-tests: failed: {ex.Message}");
            return 1;
        }
    }

    private static async Task RunServerResilienceAsync()
    {
        var reservation = new TcpListener(IPAddress.Loopback, 0);
        reservation.Start();
        var port = ((IPEndPoint)reservation.LocalEndpoint).Port;
        reservation.Stop();
        var config = new BridgeConfig { ListenHost = "127.0.0.1", Port = port, Token = "secret" };
        using var stop = new CancellationTokenSource();
        var server = Task.Run(() => new BridgeServer(config).RunAsync(stop.Token));
        await Task.Delay(100);

        using (var malformed = new TcpClient())
        {
            await malformed.ConnectAsync(IPAddress.Loopback, port);
            using var reader = new StreamReader(malformed.GetStream(), Encoding.UTF8, leaveOpen: true);
            using var writer = new StreamWriter(malformed.GetStream(), new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            await writer.WriteLineAsync("{\"type\":1,\"token\":\"secret\"}");
            Assert((await reader.ReadLineAsync())?.Contains("auth_failed") == true, "malformed auth is contained");
        }

        using (var authenticated = new TcpClient())
        {
            await authenticated.ConnectAsync(IPAddress.Loopback, port);
            using var reader = new StreamReader(authenticated.GetStream(), Encoding.UTF8, leaveOpen: true);
            using var writer = new StreamWriter(authenticated.GetStream(), new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            await writer.WriteLineAsync("{\"type\":\"auth\",\"token\":\"secret\"}");
            Assert((await reader.ReadLineAsync())?.Contains("auth_ok") == true, "server survives malformed client");
            await writer.WriteLineAsync("[]");
            await writer.WriteLineAsync("{\"type\":\"move\",\"dx\":\"bad\",\"dy\":1}");
        }

        using (var next = new TcpClient())
        {
            await next.ConnectAsync(IPAddress.Loopback, port);
            using var reader = new StreamReader(next.GetStream(), Encoding.UTF8, leaveOpen: true);
            using var writer = new StreamWriter(next.GetStream(), new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            await writer.WriteLineAsync("{\"type\":\"auth\",\"token\":\"secret\"}");
            Assert((await reader.ReadLineAsync())?.Contains("auth_ok") == true, "listener remains available");
        }

        stop.Cancel();
        try { await server; } catch (OperationCanceledException) { }
    }

    private static void Assert(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException(name);
    }
}
