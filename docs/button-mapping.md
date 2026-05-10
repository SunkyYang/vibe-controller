# Button Mapping

DualSense 手柄当前按键分配清单。以 `Sources/VibeController/main.swift` 中的实现为准。

## 已映射

| 按键 | GC API | 功能 | 备注 |
|---|---|---|---|
| R2 (右扳机, 模拟) | `rightTrigger` | 切换 OpenWhispr 录音 (`Option+\``) | 阈值 0.6 触发 / 0.4 释放；USB 下开启自适应扳机 weapon 模式；**L2 按住启动时 → 录音 paste 强制落到 Ghostty** |
| L2 (左扳机) | `leftTrigger` | 修饰键 / "Fn" | 按住时改变其它键含义 |
| R1 | `rightShoulder` | `Cmd+Shift+→` | Ghostty 下一个标签 (匹配用户 config) |
| L1 | `leftShoulder` | `Cmd+Shift+←` | Ghostty 上一个标签 |
| ✕ (Cross) | `buttonA` | `Return` | |
| ○ (Circle) | `buttonB` | `Esc` (默认) / `Delete` 长按 (L2 按住时) | |
| □ (Square) | `buttonX` | 鼠标左键 | 配合右摇杆当鼠标 |
| △ (Triangle) | `buttonY` | 短按: 聚焦 Ghostty + `claude` 回车 / 长按 (>0.55s): `claude --resume` 回车 | 通过 `NSWorkspace.didActivateApplicationNotification` 等待真正前台后再敲键, 2s 兜底 |
| D-Pad ↑ | `dpad.up` | 方向键 ↑ (默认) / `Cmd+T` 新建 Ghostty 标签 (L2 按住时) | 默认仿 macOS 长按重复 |
| D-Pad ↓ | `dpad.down` | 方向键 ↓ (默认) / 输入 `/new` + 回车 (L2 按住时) | |
| D-Pad ← | `dpad.left` | 方向键 ← | |
| D-Pad → | `dpad.right` | 方向键 → (默认) / `Cmd+D` 右分屏 (L2 按住时) | |
| 左摇杆 (模拟) | `leftThumbstick` | 鼠标光标移动 | |
| 右摇杆 (模拟) | `rightThumbstick` | 垂直滚轮 | |
| PS (Home) | `buttonHome` | `Cmd+Tab` | macOS 可能拦截；部分手柄不暴露 |

## 未映射 (可用键位)

| 按键 | GC API | 状态 |
|---|---|---|
| L3 (左摇杆按下) | `leftThumbstickButton` | 未使用 |
| R3 (右摇杆按下) | `rightThumbstickButton` | 未使用 |
| Options | `buttonOptions` | 未使用 |
| Create (左上, 旧 Share) | `buttonMenu` | 未使用 |
| 触摸板 (模拟 X/Y) | touchpad | 故意禁用 — 电容噪声漂移严重，已用右摇杆+□ 替代 |
| 触摸板按下 | touchpadButton | 故意禁用 (同上) |
| 静音键 (麦下方) | — | 硬件级，GameController 不暴露 |

## 反向参考: 常用动作 → 按键

- 打开/关闭语音输入 → R2
- 回车 / 关闭 → ✕ / ○
- 方向键导航 → D-Pad (长按重复)
- 删除字符 → L2 + ○ (长按重复)
- 切标签 → L1 / R1
- 鼠标 → 左摇杆移动 + □ 左键
- 滚动 → 右摇杆
- Cmd+Tab 切应用 → PS
- 启动/聚焦 Ghostty + 跑 `claude` → △ 短按
- 启动 Ghostty + `claude --resume` → △ 长按
- 录音直送 Claude (语音输入到 Ghostty) → L2 + R2
- Ghostty 新建标签 → L2 + ↑ (Cmd+T)
- Ghostty 右分屏 → L2 + → (Cmd+D)
- Claude `/new` → L2 + ↓

## 已知不一致

`README.md` 第 13 行 feature checklist 仍写: "Touchpad swipes → Enter (right) / Esc (left)"。
实际 `main.swift:1359-1360` 已注释禁用触摸板, `TouchpadInput` 类存在但未被 attach。
README 该条需要更新或删除。
