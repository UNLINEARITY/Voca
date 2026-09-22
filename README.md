# Voca — macOS 全局划词保存

菜单栏小工具：在任意 App 里**选中文字 → 按快捷键 → 静默保存**，右下角轻提示确认。数据全部本地存储在单个 SQLite 文件里。

## 快速开始

```bash
./build.sh          # 编译并组装 build/Voca.app
open build/Voca.app # 启动（菜单栏会出现 ❝ 图标）
```

## 首次使用：授权辅助功能（只需一次，必须手工）

1. 启动 Voca 后，随便在 Safari/备忘录里选中一段文字，按 **⌥⇧S**（默认快捷键）
2. 系统会弹出辅助功能授权提示 → 点「打开系统设置」
3. **系统设置 → 隐私与安全性 → 辅助功能** → 点 **＋** → 选择 `build/Voca.app` → 打开开关
4. 回到任意 App，选中文字再按快捷键 → 右下角出现「已保存 · 来自 XXX」

> 如果列表里已有 Voca 但开关是关的，直接打开开关即可。

## 日常使用

| 操作 | 方式 |
|---|---|
| 保存选中文字 | 选中 → `⌥⇧S`（可在菜单栏 ❝ 图标里改键） |
| 查看全部记录 | 菜单栏 ❝ → 查看全部记录（支持全文搜索） |
| 复制某条记录 | 记录行的 📄 按钮，或右键 → 复制全文 |
| 删除某条记录 | 记录行的 🗑 按钮，或右键 → 删除 |
| 修改快捷键 | 菜单栏 ❝ → 「保存快捷键」录制器，直接按新键位 |
| 退出 | 菜单栏 ❝ → 退出 Voca |

## 数据在你手上

- **位置**：`~/Library/Application Support/Voca/voca.sqlite`（单文件）
- **备份**：拷贝这一个文件即可
- **查看**：任何 SQLite 工具都能直接打开（如 `sqlite3`、DB Browser for SQLite）
- **结构**：`clips` 表（id / text / note / appName / appBundleID / wordCount / createdAt）

## 工作原理

```
选中文字 → 全局快捷键
  ├─ 主路径：Accessibility API 读选区（kAXSelectedTextAttribute）
  ├─ 降级路径：模拟 ⌘C 读剪贴板（读完自动恢复你原来的剪贴板）
  ├─ 密码框（AXSecureTextField）自动跳过
  └─ 3 秒内同文本同来源不重复入库
→ 写入本地 SQLite → 右下角 toast 确认
```

## 排障

| 症状 | 处理 |
|---|---|
| toast 提示「需要辅助功能权限」 | 按上文授权步骤操作；改过代码后需重新授权新构建的 App |
| 「未检测到选中文本」 | 该 App 可能不支持 AX 取词且剪贴板策略也失败（部分游戏/远程桌面）；可手动 ⌘C 后到记录窗口手动粘贴（v0.2 计划加入剪贴板兜底入口） |
| 快捷键没反应 | 可能与其他软件（Easydict/Bob 等）键位冲突，到菜单栏改键 |
| 重启 Mac 后要重新打开 | 系统设置 → 通用 → 登录项 → ＋ 添加 Voca.app |
| 想彻底重置 | 退出 Voca，删除 `~/Library/Application Support/Voca/` 目录，重新打开 |

## 已知限制（MVP 范围）

- 不记录浏览器 URL / 窗口标题（只记来源 App 名）——避免额外权限弹窗
- ⌘C 降级路径会短暂触碰剪贴板（约 0.3 秒后自动恢复）
- 无导出按钮——数据本身就是标准 SQLite 文件
- 无开机自启设置——用系统「登录项」管理

## 许可

本项目以 [AGPL-3.0-or-later](LICENSE) 发布，© 2026 [UNLINEARITY](https://github.com/UNLINEARITY)。

依赖 [GRDB](https://github.com/groue/GRDB.swift) 与 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 均为 MIT 许可，与 AGPL 兼容。

## 开发

```bash
swift build          # 调试编译
./build.sh           # release 编译 + 组装 .app
```

依赖：[GRDB](https://github.com/groue/GRDB.swift)（SQLite）、[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)（全局快捷键）。
