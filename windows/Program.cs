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
    private CancellationTokenSource? _serverStop;
    private Task? _serverTask;
    private bool _firstStart = true;

    public TrayContext(string configPath)
    {
        _configPath = configPath;
        var menu = new ContextMenuStrip();
        menu.Items.Add(_status);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("重新启动服务", null, (_, _) => StartServer());
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
        _serverStop?.Cancel();
        if (_serverTask is not null)
        {
            try { await _serverTask; }
            catch (OperationCanceledException) { }
            catch { }
        }
        _serverStop?.Dispose();
        _serverStop = new CancellationTokenSource();

        try
        {
            var config = JsonSerializer.Deserialize<BridgeConfig>(await File.ReadAllTextAsync(_configPath), Json.Options)
                         ?? throw new InvalidDataException("配置为空");
            config.Validate();
            SetStatus($"正在监听 {config.ListenHost}:{config.Port}");
            _serverTask = new BridgeServer(config, SetStatus).RunAsync(_serverStop.Token);
            await _serverTask;
        }
        catch (OperationCanceledException) { }
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
        finally { _firstStart = false; }
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
        if (!IPAddress.TryParse(ListenHost, out _)) throw new InvalidDataException("listenHost must be an IP address");
        if (Port is < 1 or > 65535) throw new InvalidDataException("port must be 1...65535");
        if (string.IsNullOrEmpty(Token) || Token == "change-me") throw new InvalidDataException("set a non-default token");
        if (EdgeThreshold < 0 || ReturnThreshold <= 0) throw new InvalidDataException("thresholds must be positive");
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
                try { await ServeAsync(client, cancellationToken); }
                catch (Exception ex) when ((ex is IOException or SocketException) && !cancellationToken.IsCancellationRequested)
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
        report?.Invoke($"Mac 已连接：{client.Client.RemoteEndPoint}");
        try
        {
            using var authTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            authTimeout.CancelAfter(TimeSpan.FromSeconds(5));
            var authLine = await Json.ReadLineAsync(stream, authTimeout.Token);
            if (authLine is null || !Protocol.Authenticates(authLine, config.Token))
            {
                await Json.WriteAsync(stream, new { type = "auth_failed" }, cancellationToken);
                report?.Invoke("认证失败");
                return;
            }
            await Json.WriteAsync(stream, new { type = "auth_ok" }, cancellationToken);
            report?.Invoke("Mac 已连接并通过认证");

            while (await Json.ReadLineAsync(stream, cancellationToken) is { } line)
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
            if (!root.TryGetProperty("type", out var type) || type.GetString() != "auth" ||
                !root.TryGetProperty("token", out var token) || token.ValueKind != JsonValueKind.String) return false;
            var supplied = Encoding.UTF8.GetBytes(token.GetString()!);
            var expected = Encoding.UTF8.GetBytes(expectedToken);
            return supplied.Length == expected.Length && CryptographicOperations.FixedTimeEquals(supplied, expected);
        }
        catch (JsonException) { return false; }
    }
}

internal sealed class WindowsInput
{
    private readonly BridgeConfig _config;
    private readonly ReturnAccumulator _returning;
    private readonly HashSet<ushort> _keys = [];
    private readonly HashSet<string> _buttons = [];
    private bool _active;

    public WindowsInput(BridgeConfig config)
    {
        _config = config;
        _returning = new ReturnAccumulator(config.ReturnThreshold);
    }

    public object? Handle(JsonElement message)
    {
        if (!message.TryGetProperty("type", out var typeProperty)) return null;
        var type = typeProperty.GetString();
        if (type == "enter_pc" && Number(message, "xRatio") is { } ratio)
        {
            ReleaseAll();
            var desktop = Native.Desktop();
            Native.SetCursorPos(Ratio.MapToPixel(ratio, desktop.Left, desktop.Width), desktop.Bottom - 2);
            _active = true;
            _returning.Reset();
            return null;
        }
        if (!_active) return null;

        switch (type)
        {
            case "move" when Number(message, "dx") is { } dx && Number(message, "dy") is { } dy:
                Native.MouseMove(ClampDelta(dx), ClampDelta(dy));
                if (Native.GetCursorPos(out var point))
                {
                    var desktop = Native.Desktop();
                    var atBottom = point.Y >= desktop.Bottom - _config.EdgeThreshold;
                    if (_returning.Update(atBottom, dy, Environment.TickCount64 / 1000.0))
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
                Native.Scroll(ClampDelta(Number(message, "dx") ?? 0), ClampDelta(Number(message, "dy") ?? 0));
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
        _returning.Reset();
    }

    private static double? Number(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.TryGetDouble(out var number) && double.IsFinite(number)
            ? number : null;

    private static string? Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int ClampDelta(double value) => (int)Math.Clamp(Math.Round(value), -100_000, 100_000);
}

internal sealed class ReturnAccumulator(double threshold, double idleResetSeconds = 0.5)
{
    private double _total;
    private double? _lastUpdate;
    public double Total => _total;

    public bool Update(bool atEdge, double downwardDelta, double now)
    {
        if (!atEdge || downwardDelta <= 0 || (_lastUpdate is { } last && now - last > idleResetSeconds)) _total = 0;
        if (!atEdge || downwardDelta <= 0)
        {
            _lastUpdate = null;
            return false;
        }
        _total += downwardDelta;
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
        length <= 0 ? 0 : Math.Clamp((position - origin) / length, 0, 1);

    public static int MapToPixel(double ratio, int origin, int length)
    {
        if (!double.IsFinite(ratio) || length <= 0) return origin;
        return (int)Math.Clamp(Math.Round(origin + length * Math.Clamp(ratio, 0, 1)), origin, origin + length - 1);
    }
}

internal static class Json
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    public static async Task<string?> ReadLineAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var bytes = new MemoryStream();
        var one = new byte[1];
        while (bytes.Length <= 65_536)
        {
            var count = await stream.ReadAsync(one, cancellationToken);
            if (count == 0) return bytes.Length == 0 ? null : Encoding.UTF8.GetString(bytes.ToArray());
            if (one[0] == (byte)'\n') return Encoding.UTF8.GetString(bytes.ToArray());
            if (one[0] != (byte)'\r') bytes.WriteByte(one[0]);
        }
        throw new InvalidDataException("protocol line exceeds 65536 bytes");
    }

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
        if (dy != 0) SendMouse(0, 0, unchecked((uint)(dy * 120)), Wheel);
        if (dx != 0) SendMouse(0, 0, unchecked((uint)(dx * 120)), HWheel);
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
            Assert(Ratio.FromPosition(-960, -1920, 1920) == 0.5, "virtual desktop ratio");
            Assert(Ratio.MapToPixel(2, -1920, 1920) == -1, "ratio clamp");
            Assert(Protocol.Authenticates("{\"type\":\"auth\",\"token\":\"secret\"}", "secret"), "auth accepts token");
            Assert(!Protocol.Authenticates("{\"type\":\"move\",\"token\":\"secret\"}", "secret"), "input cannot authenticate");
            Assert(!Protocol.Authenticates("{\"type\":\"auth\",\"token\":\"wrong\"}", "secret"), "auth rejects token");
            Console.WriteLine("winbridge self-tests: passed");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"winbridge self-tests: failed: {ex.Message}");
            return 1;
        }
    }

    private static void Assert(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException(name);
    }
}
