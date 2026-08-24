# MacBridge 跨设备无感键鼠控制系统 SRS v0.2

> 本版本基于 v0.1 修改屏幕物理拓扑：**Windows 显示器位于 MacBook 屏幕正上方**。  
> 其余架构、网络协议、键盘映射、输入注入、安全及异常恢复要求保持不变。

## 1. 默认物理拓扑

实际桌面布局：

```text
              Windows PC 显示器
          ┌─────────────────────┐
          │                     │
          │      Windows        │
          │                     │
          └─────────────────────┘
                    ↑
                    ↑
              鼠标继续向上推
                    ↑
          ┌─────────────────────┐
          │                     │
          │       MacBook       │
          │                     │
          └─────────────────────┘
```

Windows 位于 MacBook 屏幕**正上方**。

默认配置：

```yaml
screen:
  pcSide: top
```

用户体验目标：

> 鼠标从 MacBook 屏幕顶部继续向上推，进入 Windows；  
> 鼠标从 Windows 屏幕底部继续向下推，返回 MacBook。

---

## 2. 核心状态模型

系统仍然只有两个核心状态：

```text
MAC_ACTIVE
PC_ACTIVE
```

状态转换修改为：

```text
                 向上穿越
MAC_ACTIVE ─────────────────► PC_ACTIVE

                 向下穿越
PC_ACTIVE ──────────────────► MAC_ACTIVE
```

---

## 3. Mac → Windows 穿越逻辑

### 3.1 触发边界

MacBridge 应监听 MacBook 当前显示器的**顶部边缘**。

不能因为鼠标仅仅到达顶部就切换。

必须满足：

```text
cursor.y <= topEdgeThreshold
AND
持续产生向上的鼠标移动
AND
累计 outwardDelta >= crossingThreshold
```

注意：

macOS 坐标系具体方向由所使用的 API 决定。

实现时不要直接假设：

```text
向上 = dy < 0
```

应先统一转换成逻辑坐标：

```text
UP
DOWN
LEFT
RIGHT
```

或者归一化：

```text
normalizedDeltaX
normalizedDeltaY
```

以下 SRS 使用：

```text
向上移动：deltaY < 0
向下移动：deltaY > 0
```

作为逻辑定义。

---

## 4. 顶部穿越条件

推荐初始参数：

```text
edgeThreshold = 2px
crossingThreshold = 10px
```

示例：

鼠标已经到达 MacBook 顶部：

```text
y = 0
```

用户继续在触控板向上移动：

```text
deltaY = -3
deltaY = -4
deltaY = -5
```

累计向外移动：

```text
outwardDelta = 12px
```

满足阈值后：

```text
MAC_ACTIVE → PC_ACTIVE
```

---

## 5. 顶部边缘阻尼

必须实现轻微边缘阻尼，避免误切换。

建议：

```text
0 - 5px
保持在 Mac

5 - 10px
继续累积穿越意图，但仍停留在 Mac

>= 10px
进入 Windows
```

逻辑示例：

```text
if cursorAtTopEdge():

    if deltaY < 0:
        outwardDelta += abs(deltaY)
    else:
        outwardDelta = 0

    if outwardDelta >= crossingThreshold:
        enterWindows()
```

如果用户：

- 停止移动
- 向下移动
- 离开顶部边缘

则：

```text
outwardDelta = 0
```

---

## 6. 进入 Windows

触发穿越后，MacBridge：

1. 将状态设置为：

```text
PC_ACTIVE
```

2. 记录当前 Mac 鼠标位置。

3. 拦截后续键盘事件。

4. 拦截后续鼠标/触控板事件。

5. Mac 光标隐藏或冻结在顶部。

6. 向 Windows 发送：

```json
{
  "type": "enter_pc",
  "xRatio": 0.42
}
```

注意：

由于穿越方向变成上下关系，因此原来的：

```text
yRatio
```

修改为：

```text
xRatio
```

---

## 7. Windows 初始鼠标位置

Windows 收到：

```text
ENTER_PC
```

后，应把鼠标放到 Windows 显示区域的**底部边缘**。

视觉效果：

```text
          Windows
┌──────────────────────┐
│                      │
│                      │
│          ↑           │
└──────────●───────────┘
           ↑
       鼠标进入点

           ↑
           ↑

┌──────────●───────────┐
│        MacBook       │
└──────────────────────┘
```

Windows Y 坐标：

```text
y = windowsScreenHeight - 2
```

X 坐标按照 Mac 穿越位置进行比例映射。

计算：

```text
xRatio =
    macCursorX / macScreenWidth
```

Windows：

```text
windowsX =
    xRatio * windowsScreenWidth
```

这样：

- 从 Mac 左上方进入，Windows 也从偏左位置出现。
- 从 Mac 中间进入，Windows 从底部中间出现。
- 从 Mac 右上方进入，Windows 从偏右位置出现。

---

## 8. PC_ACTIVE 鼠标控制

进入 Windows 后：

MacBook 触控板继续产生：

```text
deltaX
deltaY
```

MacBridge 发送：

```json
{
  "type": "move",
  "dx": 12,
  "dy": -4
}
```

WinBridge 使用 Windows `SendInput` 注入相对鼠标移动。

此时 Windows 自己负责：

- 多显示器移动
- 鼠标加速度
- 窗口拖拽
- 点击
- 滚动

MacBridge 不需要理解 Windows 内部所有显示器拓扑。

---

## 9. Windows 多显示器处理原则

假设 Windows PC 实际连接两块外接显示器：

```text
┌──────────────┐ ┌──────────────┐
│ Windows 屏 1 │ │ Windows 屏 2 │
└──────────────┘ └──────────────┘
        Windows Desktop

             ↑
             ↑

       ┌──────────────┐
       │   MacBook    │
       └──────────────┘
```

MVP 不要求 MacBridge 理解：

```text
Windows 屏 1
Windows 屏 2
```

具体如何排列。

进入 Windows 后：

> 所有 Windows 显示器视为一个 Windows 虚拟桌面。

WinBridge 应根据 Windows 虚拟桌面坐标处理鼠标。

---

## 10. 推荐进入区域

如果 Windows 有两块左右排列的显示器：

```text
┌──────────────┬──────────────┐
│ Windows 屏 1 │ Windows 屏 2 │
└──────────────┴──────────────┘
```

MacBook 位于两块显示器下方：

```text
        ┌──────────────┐
        │   MacBook    │
        └──────────────┘
```

MVP 推荐：

> MacBook 顶边映射到整个 Windows 虚拟桌面底边。

即：

```text
MacBook 最左侧
↓
Windows 虚拟桌面最左侧

MacBook 中间
↓
Windows 虚拟桌面中间

MacBook 最右侧
↓
Windows 虚拟桌面最右侧
```

计算：

```text
xRatio =
    macCursorX / macScreenWidth

windowsX =
    virtualDesktopLeft
    + virtualDesktopWidth * xRatio
```

进入位置：

```text
windowsY =
    virtualDesktopBottom - 2
```

---

## 11. Windows → Mac 返回逻辑

返回边界由原来的：

```text
Windows 左边缘
```

修改为：

```text
Windows 底部边缘
```

当 Windows 鼠标达到：

```text
cursor.y >= virtualDesktopBottom - edgeThreshold
```

并且 MacBook 触控板仍持续产生：

```text
向下移动
```

累计超过：

```text
returnThreshold
```

则触发：

```text
RETURN_MAC
```

推荐：

```text
returnThreshold = 10px
```

---

## 12. 返回 Mac 的阻尼

不能因为 Windows 鼠标碰到底部就立即返回 Mac。

例如 Windows 用户可能正在：

- 点击任务栏
- 操作底部按钮
- 拖动窗口
- 操作 IDE 底部面板

因此需要同样的穿越意图判断：

```text
鼠标已经位于 Windows 底部
+
用户继续向下推动触控板
+
累计超过阈值
```

才允许：

```text
PC_ACTIVE → MAC_ACTIVE
```

---

## 13. Windows 返回事件

WinBridge 返回：

```json
{
  "type": "return_mac",
  "xRatio": 0.51
}
```

这里使用：

```text
xRatio
```

而不是：

```text
yRatio
```

---

## 14. 返回 MacBook

MacBridge 收到：

```text
RETURN_MAC
```

之后：

1. 状态切换：

```text
PC_ACTIVE → MAC_ACTIVE
```

2. 恢复 macOS 键盘输入。

3. 恢复 macOS 鼠标及触控板事件。

4. 恢复 Mac 光标。

5. 根据 Windows 返回位置计算 Mac X 坐标：

```text
macX =
    macScreenWidth * xRatio
```

6. Mac Y 坐标：

```text
macY = 2
```

即光标出现在 MacBook 屏幕顶部。

视觉效果：

```text
          Windows
┌──────────────────────┐
│                      │
│          ↓           │
└──────────●───────────┘
           ↓
           ↓
┌──────────●───────────┐
│                      │
│       MacBook        │
└──────────────────────┘
```

---

## 15. 配置修改

Mac 配置：

```yaml
windows:
  host: 192.168.1.100
  port: 24800

screen:
  pcSide: top
  crossingThreshold: 10
  returnThreshold: 10
  edgeThreshold: 2

mouse:
  sensitivity: 1.0
  scrollScale: 1.0

auth:
  token: change-me
```

---

## 16. 协议修改

进入 Windows：

```json
{
  "type": "enter_pc",
  "xRatio": 0.42
}
```

返回 Mac：

```json
{
  "type": "return_mac",
  "xRatio": 0.51
}
```

其他协议保持不变：

```json
{"type":"move","dx":14,"dy":-2}
{"type":"mouse_down","button":"left"}
{"type":"mouse_up","button":"left"}
{"type":"scroll","dx":0,"dy":12}
{"type":"key_down","key":"A","meta":["command"]}
{"type":"key_up","key":"A","meta":["command"]}
```

---

## 17. 核心状态机伪代码

### MacBridge

```text
state = MAC_ACTIVE

onMouseMove(event):

    if state == MAC_ACTIVE:

        if cursorAtTopEdge():

            if event.dy < 0:

                outwardDelta += abs(event.dy)

                if outwardDelta >= crossingThreshold:

                    xRatio =
                        cursor.x / screen.width

                    state = PC_ACTIVE

                    lockMacCursor()

                    send ENTER_PC(xRatio)

            else:

                outwardDelta = 0


    else if state == PC_ACTIVE:

        send MOVE(event.dx, event.dy)
```

---

### WinBridge

```text
on ENTER_PC(xRatio):

    x =
        virtualDesktop.left
        + virtualDesktop.width * xRatio

    y =
        virtualDesktop.bottom - 2

    setCursor(x, y)
```

处理鼠标：

```text
on MOVE(dx, dy):

    moveWindowsCursor(dx, dy)

    if cursorAtBottomEdge():

        if dy > 0:

            returnDelta += dy

            if returnDelta >= returnThreshold:

                xRatio =
                    (
                        cursor.x
                        - virtualDesktop.left
                    )
                    / virtualDesktop.width

                send RETURN_MAC(xRatio)

                returnDelta = 0

        else:

            returnDelta = 0
```

---

### MacBridge 返回

```text
on RETURN_MAC(xRatio):

    state = MAC_ACTIVE

    releaseCapturedKeys()

    restoreMacCursor()

    macX =
        macScreen.width * xRatio

    setCursorPosition(
        macX,
        2
    )
```

---

## 18. 修订后的验收场景

### TC-01 Mac → Windows

操作：

1. 鼠标移至 MacBook 顶部。
2. 停止移动。

结果：

```text
仍然在 Mac。
```

继续：

3. 在触控板上继续向上推动超过 10px。

结果：

```text
MAC_ACTIVE → PC_ACTIVE
```

Windows 鼠标：

```text
从 Windows 虚拟桌面底部进入。
```

---

### TC-02 横向位置连续性

从 MacBook 顶部偏左位置穿越。

Windows 光标：

```text
应出现在 Windows 底部偏左位置。
```

从 MacBook 顶部中央穿越。

Windows 光标：

```text
应出现在 Windows 底部中央附近。
```

---

### TC-03 Windows → Mac

Windows 鼠标移动至 Windows 虚拟桌面底部。

停止。

结果：

```text
仍然控制 Windows。
```

继续向下推动触控板超过阈值。

结果：

```text
PC_ACTIVE → MAC_ACTIVE
```

Mac 鼠标：

```text
从 MacBook 顶部进入。
```

---

### TC-04 Windows 任务栏操作

鼠标移动至 Windows 底部任务栏。

进行：

```text
点击
轻微移动
窗口操作
```

不得返回 Mac。

只有：

```text
到达底部
+
持续向下推动
+
超过 returnThreshold
```

才允许返回。

---

## 19. 最终交互定义

整个物理空间应被用户理解为：

```text
        Windows 计算空间
┌────────────────────────┐
│                        │
│                        │
└────────────────────────┘
             ↕
       无感穿越边界
             ↕
      MacBook 计算空间
┌────────────────────────┐
│                        │
│                        │
└────────────────────────┘
```

用户不需要：

- 快捷键
- 点击切换
- KVM
- 切换键盘
- 切换触控板

唯一交互规则：

> **向上推，进入 Windows。向下推，回到 Mac。**

这条规则应作为 MVP 最核心的体验约束。