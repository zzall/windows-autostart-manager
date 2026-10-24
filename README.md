# Windows 自启动管理台（Qoder / Claude Skill）

一个 AI Agent 技能：一句话打开本地网页管理台，可视化管理 Windows 开机自启动项。

## 功能

- 扫描四类自启动入口：注册表 Run 键（HKCU/HKLM）、启动文件夹、开机/登录计划任务、非 svchost 服务
- 智能梳理：建议聚合 / 建议改可选 / 可一键启动 / 保持现状（系统与驱动自动归类）
- 分组管理：新建/重命名/删除组，整组一键启动
- 在线启停：检测每项进程是否在跑，一键启动 / 停止进程（含子进程树）
- 安全删除：所有删除需二次确认；注册表项删除前自动备份可恢复；启动文件夹文件进回收站；永久删除计划任务/服务默认关闭，需手动开启 `advanced` 模式
- 标签体系：系统 / 驱动 / 第三方自动标签 + 自定义标签筛选

## 安装

需要已安装 Qoder CLI（或兼容 Agent Skills 的 CLI）：

```bash
npx skills add zzall/windows-autostart-manager@windows-autostart-manager
```

## 使用

对 Agent 说以下任意一句，或输入 `/windows-autostart-manager`：

- “打开自启动管理台”
- “看看电脑都自启了什么”
- “管理开机自启”

Agent 会在本机拉起一个只监听 `127.0.0.1:8788` 的网页服务并打开浏览器。

## 依赖

- 零第三方依赖。装了 Node.js 用 Node 后端；没装则自动回退到 Windows 自带的 PowerShell 后端。
- 禁用/恢复注册表项与启动文件夹：普通权限即可。
- 计划任务与服务操作：需要管理员权限（以管理员身份重新运行即可）。

## 数据与隐私

- 所有数据只在本机流转：服务仅监听 127.0.0.1，无任何外部网络请求。
- 配置与备份存放于 `%APPDATA%\windows-autostart-manager\config.json`，删除该目录即清除全部痕迹。

## 目录结构

```
windows-autostart-manager/
├── SKILL.md            # Agent 说明书与触发条件
├── scripts/server.mjs  # Node 后端
├── scripts/server.ps1  # PowerShell 后端（无 Node 时兜底）
├── scripts/start.cmd   # 一键启动器
└── assets/index.html   # 网页界面
```

## License

MIT
