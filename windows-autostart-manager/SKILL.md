---
name: windows-autostart-manager
description: Windows 自启动管理台——启动本地网页界面管理开机自启项（注册表 Run 键/启动文件夹/计划任务/服务）。当用户要求"打开自启动管理台""管理开机自启""禁用/恢复启动项""一键启动某组程序""按分组批量启停自启服务""看看电脑都自启了什么"时使用。内置 Node 与纯 PowerShell 双后端（自动选择），零第三方依赖，带二次确认删除与进程在线启停。仅监听 127.0.0.1。
---

# Windows 自启动管理台

## Overview

一个本地网页管理台：扫描并分类 Windows 全部自启动入口（HKCU/HKLM 注册表 Run 键、用户/公共启动文件夹、开机/登录计划任务、非 svchost 服务），支持启用/禁用/删除（二次确认）、分组一键启停、标签筛选、进程在线启停。数据与备份存 `%APPDATA%\windows-autostart-manager\config.json`，不写注册表以外的隐私数据，仅监听 127.0.0.1。

## 启动步骤

1. 检查是否已在运行：`netstat -ano | findstr ":8788.*LISTENING"`。已运行则直接打开浏览器访问该端口即可。
2. 未运行时后台拉起（择一）：
   - 有 Node（`node -v` 成功）：`node scripts/server.mjs`（后台运行）
   - 无 Node：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/server.ps1`（后台运行）
   - 或直接运行 `scripts/start.cmd`（自动完成以上判断并打开浏览器）
3. 服务启动后 stdout 打印 `OK windows-autostart-manager http://127.0.0.1:<port>/`；默认 8788，被占用时自动尝试到 8792。用系统默认浏览器打开该地址。
4. 把地址告诉用户，管理动作（禁用、分组、启停）都在网页里完成，不需要你继续操作。

## 停止服务

用户要求关闭时：找到监听 8788-8792 的 node/powershell 进程并结束（`netstat -ano` 取 PID → `taskkill /PID x /F`）。配置与备份保留在 `%APPDATA%\windows-autostart-manager\`。

## 安全须知（必须遵守）

- 永久删除计划任务/服务默认被后端拒绝，需用户自行把 config.json 的 `advanced` 改为 `true` 才放开。用户提出"删除任务/服务"且被拒时，向用户解释此开关，不要替用户打开。
- 计划任务与服务的操作在普通权限下会返回 Access denied。此时提示用户：以管理员身份重新运行 `scripts/start.cmd`（会弹 UAC），不要静默重试。
- 删除注册表项前自动备份进 config.json（界面可恢复）；启动文件夹文件删除走回收站。向用户转述这些边界后再动手。
- 本工具只管理启动项与进程，绝不卸载软件、不动系统组件（系统/驱动标签项在界面中已归入"保持现状"类）。

## 排障

- 页面空白：扫描需 3-8 秒（多次 PowerShell 调用），等待后刷新。
- 端口冲突：8788-8792 全占用时后端打印 `ERROR: 端口…`，让用户关闭旧实例。
- 包装脚本（vbs/bat 拉起别的 exe）进程状态不准：在 config.json 的 `meta.<项名>.match` 填真实进程关键字（如 `frpc`）即可正确检测与停止。

## Resources

- `scripts/server.mjs` — Node 后端（完整实现）
- `scripts/server.ps1` — 纯 PowerShell 后端（同 API，无依赖兜底）
- `scripts/start.cmd` — 一键启动器（自动选后端 + 开浏览器）
- `assets/index.html` — 网页界面（由后端伺服，勿单独打开）
