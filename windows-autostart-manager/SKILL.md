---
name: windows-autostart-manager
description: Windows 自启动管理台——启动本地网页界面管理开机自启项（注册表 Run 键/启动文件夹/计划任务/服务）。当用户要求"打开自启动管理台""管理开机自启""禁用/恢复启动项""一键启动某组程序""按分组批量启停自启服务""看看电脑都自启了什么"时使用。内置 Node 与纯 PowerShell 双后端（自动选择），零第三方依赖，带二次确认删除与进程在线启停。仅监听 127.0.0.1。
---

# Windows 自启动管理台

## Overview

一个本地网页管理台：扫描并分类 Windows 全部自启动入口（HKCU/HKLM 注册表 Run 键、用户/公共启动文件夹、开机/登录计划任务、非 svchost 服务），支持启用/禁用/删除（二次确认）、分组一键启停、标签筛选、进程在线启停。数据与备份存 `%APPDATA%\windows-autostart-manager\config.json`，不写注册表以外的隐私数据，仅监听 127.0.0.1。

## 启动步骤

1. 检查是否已在运行：`netstat -ano | findstr ":28788.*LISTENING"`。已运行则直接打开浏览器访问该端口即可。
2. 未运行时后台拉起（择一）：
   - 有 Node（`node -v` 成功）：`node scripts/server.mjs`（后台运行）
   - 无 Node：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/server.ps1`（后台运行）
   - 或直接运行 `scripts/start.cmd`（自动完成以上判断并打开浏览器）
3. 服务启动后 stdout 打印 `OK windows-autostart-manager http://127.0.0.1:<port>/`；默认 28788，被占用时自动尝试到 28808。用系统默认浏览器打开该地址。
4. 把地址告诉用户，管理动作（禁用、分组、启停）都在网页里完成，不需要你继续操作。

## 停止服务

用户要求关闭时：找到监听 28788-28808 的 node/powershell 进程并结束（`netstat -ano` 取 PID → `taskkill /PID x /F`）。配置与备份保留在 `%APPDATA%\windows-autostart-manager\`。

## 对话操作（不开界面也能干活）

后端就绪后，你可以直接用 HTTP API 替用户操作，用户一句话即可完成，无需打开网页：

- `GET /api/state` — 返回全部自启动项（含来源 source、启动类型 startupType、标签 tags、是否运行 running、进程 pids、分组 groupsOf、权限 elevated）
- `POST /api/action` — JSON body 按 op 执行：

| op | 参数 | 作用 |
|---|---|---|
| run-disable / run-enable | source,name | 禁用/恢复注册表自启（自动备份，可恢复） |
| folder-disable / folder-enable | name,file | 移出/放回启动文件夹 |
| task-disable / task-enable / task-run | name | 计划任务开关与触发（需管理员） |
| svc-mode | name,mode(auto/delayed/manual/disabled) | 改服务启动类型（需管理员） |
| svc-start / svc-stop | name | 启停服务（需管理员） |
| launch | command | 一键启动某项 |
| stop | name,command | 按命令行特征停止该项进程（含子进程树） |
| delete | source,name,file | 删除（注册表项先备份；文件进回收站；任务/服务需 advanced） |
| set-tags / save-groups / save-meta | 见接口 | 标签、分组、分类持久化 |
| relaunch-elevated | 无 | 弹 UAC，以管理员身份重启服务并接管端口 |

典型对话："我电脑都自启了什么"→ 拉 state 汇总分类汇报；"把豆包自启关了"→ run-disable；"把开发组全拉起来"→ 遍历 groups 成员逐个 launch/svc-start。

操作守则：禁用/恢复/启停可直接执行并报告结果；**delete 一律先向用户复述对象与后果、得到确认再调**；遇 elevated=false 且操作被拒时，引导用户点页面按钮或调 relaunch-elevated。

## 安全须知（必须遵守）

- 永久删除计划任务/服务默认被后端拒绝，需用户自行把 config.json 的 `advanced` 改为 `true` 才放开。用户提出"删除任务/服务"且被拒时，向用户解释此开关，不要替用户打开。
- 计划任务与服务的操作在普通权限下会返回 Access denied。此时告诉用户：点页面顶部权限条旁的"申请管理员权限"按钮（会弹一次 UAC，确认后新实例接管并自动退出旧实例），或者以管理员身份重新运行 `scripts/start.cmd`。不要静默重试。
- 删除注册表项前自动备份进 config.json（界面可恢复）；启动文件夹文件删除走回收站。向用户转述这些边界后再动手。
- 本工具只管理启动项与进程，绝不卸载软件、不动系统组件（系统/驱动标签项在界面中已归入"保持现状"类）。

## 排障

- 页面空白：扫描需 3-8 秒（多次 PowerShell 调用），等待后刷新。
- 端口冲突：28788-28808 全占用时后端打印 `ERROR: 端口…`，让用户关闭旧实例。
- 包装脚本（vbs/bat 拉起别的 exe）进程状态不准：在 config.json 的 `meta.<项名>.match` 填真实进程关键字（如 `frpc`）即可正确检测与停止。

## Resources

- `scripts/server.mjs` — Node 后端（完整实现）
- `scripts/server.ps1` — 纯 PowerShell 后端（同 API，无依赖兜底）
- `scripts/start.cmd` — 一键启动器（自动选后端 + 开浏览器）
- `assets/index.html` — 网页界面（由后端伺服，勿单独打开）
