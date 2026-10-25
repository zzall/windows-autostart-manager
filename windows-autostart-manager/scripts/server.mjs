// windows-autostart-manager · Node 后端（本机 127.0.0.1，默认端口 8788，占用时自动 +1 至 8798）
import http from 'node:http';
import { execFile } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const pexec = promisify(execFile);
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const UI_FILE = path.join(ROOT, '..', 'assets', 'index.html');
const DATA_DIR = path.join(process.env.APPDATA || ROOT, 'windows-autostart-manager');
const CONFIG_FILE = path.join(DATA_DIR, 'config.json');
const DEFAULT_CFG = { groups: {}, meta: {}, disabledRun: {}, advanced: false };

const PS = 'powershell.exe';
async function ps(script) {
  const { stdout } = await pexec(PS, ['-NoProfile', '-Command',
    `[Console]::OutputEncoding=[Text.Encoding]::UTF8; ${script}`],
    { maxBuffer: 32 * 1024 * 1024, windowsHide: true });
  return stdout;
}
const q = s => `'${String(s).replace(/'/g, "''")}'`;

function loadConfig() {
  if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });
  if (!existsSync(CONFIG_FILE)) writeFileSync(CONFIG_FILE, JSON.stringify(DEFAULT_CFG, null, 2), 'utf8');
  return JSON.parse(readFileSync(CONFIG_FILE, 'utf8').replace(/^﻿/, '') || '{}');
}
function saveConfig(cfg) { globalThis.__scanP = null; writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), 'utf8'); }

// ---------- 进程匹配 ----------
let PROCS = [];
const norm = s => String(s || '').replace(/\//g, '\\').toLowerCase();
function targets(cmd) {
  const re = /([a-z]:[^\s"']+|[\w.\-\\\u00ff-\uffff]+\.(?:py|mjs|cjs|js|vbs|bat|cmd|exe))/gi;
  const t = []; let m;
  while ((m = re.exec(cmd || ''))) t.push(m[1]);
  return {
    script: t.find(x => /\.(py|mjs|cjs|js|vbs|bat|cmd)$/i.test(x)),
    exe: t.find(x => /\.exe$/i.test(x)),
  };
}
function refreshSelf() {
  const SELF = new Set([process.pid]);
  let cur = PROCS.find(p => p.ProcessId === process.pid);
  while (cur) { SELF.add(cur.ParentProcessId); cur = PROCS.find(p => p.ProcessId === cur.ParentProcessId); }
  globalThis.__SELF = SELF;
}
function matchPids(it) {
  let nk, base, tail2 = '', byName = false;
  if (it.matchKey) { nk = norm(it.matchKey); base = nk.split('\\').pop(); byName = true; }
  else {
    const { script, exe } = targets(it.command || '');
    const key = script || exe;
    if (!key) return [];
    if (!script && /^(powershell|cmd|wscript|cscript|bash|sh|conhost|explorer).exe$/i.test(key)) return [];
    nk = norm(key); base = nk.split('\\').pop();
    tail2 = nk.split('\\').slice(-2).join('\\');
    byName = !script && !!exe && exe.includes('\\');
  }
  return PROCS.filter(p => {
    if ((globalThis.__SELF || new Set()).has(p.ProcessId)) return false;
    const cl = norm(p.CommandLine), nm = (p.Name || '').toLowerCase();
    if (cl.includes(nk) || (tail2 && cl.includes(tail2))) return true;
    if (byName && (nm === base || nm === base + '.exe')) return true;
    return false;
  }).map(p => p.ProcessId);
}

// ---------- 扫描 ----------
const RUN_KEY = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const RUN_KEY_HKLM = 'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const STARTUP_DIR = process.env.APPDATA + '\\Microsoft\\Windows\\Start Menu\\Programs\\Startup';
const STARTUP_OFF = path.join(STARTUP_DIR, '_已关闭自启');

globalThis.PROGRESS = [];
function stage(key, label, state, count) {
  let s = globalThis.PROGRESS.find(x => x.key === key);
  if (!s) { s = { key, label }; globalThis.PROGRESS.push(s); }
  s.state = state; if (count !== undefined) s.count = count;
}
async function scan() {
  globalThis.PROGRESS = [];
  stage('startup', '注册表 Run 键与启动文件夹', 'run');
  const cfg = loadConfig();
  const items = [];
  try {
    const j = JSON.parse(await ps(`Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User | ConvertTo-Json -Depth 2`));
    for (const it of (Array.isArray(j) ? j : [j]).filter(Boolean)) {
      const loc = it.Location || '';
      let source = 'other';
      if (/HKU|HKCU/.test(loc)) source = 'run-user';
      else if (/HKLM/.test(loc)) source = 'run-machine';
      else if (loc === 'Startup') source = 'startup-folder';
      else if (loc === 'Common Startup') source = 'startup-folder-common';
      items.push({ id: `${source}:${it.Name}`, source, name: it.Name, command: it.Command });
    }
  } catch (e) { items.push({ id: 'error:startup', source: 'error', name: '扫描启动项失败', command: String(e).slice(0, 200) }); }
  try {
    const files = JSON.parse(await ps(`Get-ChildItem -File ${q(STARTUP_DIR)} | Select-Object Name | ConvertTo-Json`));
    const names = (Array.isArray(files) ? files : [files]).filter(Boolean).map(f => f.Name);
    for (const it of items) if (it.source === 'startup-folder') {
      const hit = names.find(n => n === it.name || path.parse(n).name === it.name || it.name + '.lnk' === n);
      if (hit) it.file = hit;
    }
  } catch (e) {}
  for (const [k, val] of Object.entries(cfg.disabledRun || {})) {
    const [source, ...rest] = k.split('|'); const name = rest.join('|');
    items.push({ id: `${source}-off:${name}`, source: `${source}-off`, name, command: val });
  }
  if (existsSync(STARTUP_OFF)) {
    try {
      const files = JSON.parse(await ps(`Get-ChildItem -File ${q(STARTUP_OFF)} | Select-Object Name | ConvertTo-Json`));
      for (const f of (Array.isArray(files) ? files : [files]).filter(Boolean))
        items.push({ id: `startup-folder-off:${f.Name}`, source: 'startup-folder-off', name: f.Name, file: f.Name, command: '(已移出到 _已关闭自启 文件夹)' });
    } catch (e) {}
  }
  stage('startup', '注册表 Run 键与启动文件夹', 'done', items.length);
  stage('services', 'Windows 服务', 'run');
  try {
    const j = JSON.parse(await ps(`Get-CimInstance Win32_Service | Where-Object {$_.PathName -notmatch 'svchost'} | Select-Object Name,DisplayName,State,StartMode,PathName | ConvertTo-Json -Depth 2`));
    for (const s of (Array.isArray(j) ? j : [j]).filter(Boolean)) {
      if (!s.PathName) continue;
      if (/System32\\|SysWOW64\\|windir/i.test(s.PathName) && !/DriverStore|sppsvc/.test(s.PathName)) continue;
      items.push({ id: `service:${s.Name}`, source: 'service', name: s.Name, display: s.DisplayName, command: s.PathName, state: s.State, startType: s.StartMode });
    }
  } catch (e) { items.push({ id: 'error:svc', source: 'error', name: '扫描服务失败', command: String(e).slice(0, 200) }); }
  stage('services', 'Windows 服务', 'done', items.filter(i => i.source === 'service').length);
  stage('tasks', '计划任务', 'run');
  try {
    const j = JSON.parse(await ps(`Get-ScheduledTask | Where-Object {$_.TaskPath -notmatch '^\\\\Microsoft\\\\'} | ForEach-Object { $t=$_; $trg=($t.Triggers | ForEach-Object {$_.CimClass.CimClassName}) -join ','; if($trg -match 'Boot|Logon'){ [PSCustomObject]@{Task=$t.TaskName; State=$t.State; Trig=$trg; Exec=(($t.Actions | ForEach-Object {$_.Execute + ' ' + $_.Arguments}) -join ' | ')} } } | ConvertTo-Json -Depth 2`));
    for (const t of (Array.isArray(j) ? j : [j]).filter(Boolean)) {
      items.push({ id: `task:${t.Task}`, source: 'task', name: t.Task, command: (t.Exec || '').trim(), state: String(t.State), trigger: t.Trig || '' });
    }
  } catch (e) { items.push({ id: 'error:task', source: 'error', name: '扫描计划任务失败', command: String(e).slice(0, 200) }); }
  stage('tasks', '计划任务', 'done', items.filter(i => i.source === 'task').length);
  stage('procs', '进程运行状态', 'run');

  let elevated = false;
  try { elevated = (await ps(`([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`)).trim() === 'True'; } catch (e) {}
  try {
    const j = JSON.parse(await ps(`Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Depth 1 -Compress`));
    PROCS = (Array.isArray(j) ? j : [j]).filter(Boolean);
  } catch (e) { PROCS = []; }
  refreshSelf();
  const meta = cfg.meta || {};
  const groups = cfg.groups || {};
  for (const it of items) {
    const m = meta[it.name] || {};
    it.suggestion = m.suggestion || null;
    it.note = m.note || '';
    it.userTags = m.tags || [];
    it.matchKey = m.match || null;
    it.startupType =
      it.source.startsWith('run-') ? '登录自启·注册表' :
      it.source.startsWith('startup-folder') ? '登录自启·启动文件夹' :
      it.source === 'task' ? '计划任务·' + (/Boot/.test(it.trigger || '') ? (/Logon/.test(it.trigger || '') ? '开机+登录' : '开机') : '登录') :
      it.source === 'service' ? '服务·' + ({ Auto: '自动', Manual: '手动', Disabled: '禁用' }[it.startType] || it.startType) : '';
    const cmd = (it.command || '') + ' ' + it.name;
    const auto = [];
    if (it.source === 'run-machine' || /system32|syswow64|windir/i.test(cmd)) auto.push('系统');
    else if (it.source === 'service' && /driverstore|nvidia|intel|realtek/i.test(cmd)) auto.push('驱动');
    else auto.push('第三方');
    it.tags = [...new Set([...auto, ...it.userTags])];
    it.groupsOf = Object.entries(groups).filter(([, ms]) => ms.includes(it.name)).map(([g]) => g);
    if (it.source === 'service') it.running = it.state === 'Running';
    else { const pids = matchPids(it); it.running = pids.length > 0; it.pids = pids; }
  }
  stage('procs', '进程运行状态', 'done', items.filter(i => i.running).length);
  return { groups, disabledRun: cfg.disabledRun || {}, elevated, advanced: !!cfg.advanced, items };
}

// ---------- 操作 ----------
async function actions(body) {
  const cfg = loadConfig();
  const op = body.op;
  if (op === 'run-disable') {
    const key = body.source === 'run-machine' ? RUN_KEY_HKLM : RUN_KEY;
    const cur = await ps(`if(Test-Path ${q(key)}){ (Get-Item ${q(key)}).GetValue(${q(body.name)}) }`);
    const val = cur.trim();
    if (!val) throw new Error('注册表中找不到该值');
    cfg.disabledRun = cfg.disabledRun || {};
    cfg.disabledRun[`${body.source}|${body.name}`] = val;
    saveConfig(cfg);
    await ps(`Remove-ItemProperty -Path ${q(key)} -Name ${q(body.name)} -Force`);
    return { ok: true, msg: `已禁用并备份：${body.name}` };
  }
  if (op === 'run-enable') {
    const key = body.source === 'run-machine' ? RUN_KEY_HKLM : RUN_KEY;
    const saved = (cfg.disabledRun || {})[`${body.source}|${body.name}`];
    if (!saved) throw new Error('没有备份记录，无法恢复');
    await ps(`New-ItemProperty -Path ${q(key)} -Name ${q(body.name)} -Value ${q(saved)} -PropertyType String -Force | Out-Null`);
    delete cfg.disabledRun[`${body.source}|${body.name}`];
    saveConfig(cfg);
    return { ok: true, msg: `已恢复自启：${body.name}` };
  }
  if (op === 'folder-disable') {
    const f = path.join(STARTUP_DIR, body.file || body.name);
    if (!existsSync(f)) throw new Error('文件不存在: ' + f);
    await ps(`New-Item -ItemType Directory -Force -Path ${q(STARTUP_OFF)} | Out-Null; Move-Item -Force ${q(f)} ${q(path.join(STARTUP_OFF, body.file || body.name))}`);
    return { ok: true, msg: `已移出启动文件夹：${body.file || body.name}` };
  }
  if (op === 'folder-enable') {
    await ps(`Move-Item -Force ${q(path.join(STARTUP_OFF, body.file || body.name))} ${q(path.join(STARTUP_DIR, body.file || body.name))}`);
    return { ok: true, msg: `已放回启动文件夹：${body.file || body.name}` };
  }
  if (op === 'task-disable') { await ps(`Disable-ScheduledTask -TaskName ${q(body.name)} | Out-Null`); return { ok: true, msg: `已禁用计划任务：${body.name}` }; }
  if (op === 'task-enable') { await ps(`Enable-ScheduledTask -TaskName ${q(body.name)} | Out-Null`); return { ok: true, msg: `已启用计划任务：${body.name}` }; }
  if (op === 'task-run') { await ps(`Start-ScheduledTask -TaskName ${q(body.name)}`); return { ok: true, msg: `已触发：${body.name}` }; }
  if (op === 'svc-mode') {
    const map = { auto: 'Automatic', manual: 'Manual', delayed: 'Automatic', disabled: 'Disabled' };
    await ps(`Set-Service -Name ${q(body.name)} -StartupType ${q(map[body.mode] || body.mode)}` +
      (body.mode === 'delayed' ? `; sc.exe config ${q(body.name)} start= delayed-auto | Out-Null` : ''));
    return { ok: true, msg: `服务 ${body.name} 启动类型已改为 ${body.mode}` };
  }
  if (op === 'svc-start') { await ps(`Start-Service -Name ${q(body.name)}`); return { ok: true, msg: `已启动服务：${body.name}` }; }
  if (op === 'svc-stop') { await ps(`Stop-Service -Name ${q(body.name)} -Force`); return { ok: true, msg: `已停止服务：${body.name}` }; }
  if (op === 'launch') {
    await ps(`Start-Process cmd -ArgumentList '/c','${String(body.command).replace(/'/g, "''")}' -WindowStyle Hidden`);
    return { ok: true, msg: '已发出启动命令' };
  }
  if (op === 'stop') {
    const j = JSON.parse(await ps(`Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Depth 1 -Compress`));
    PROCS = (Array.isArray(j) ? j : [j]).filter(Boolean);
    refreshSelf();
    const it = { name: body.name, command: body.command || '', matchKey: (cfg.meta && cfg.meta[body.name] && cfg.meta[body.name].match) || null };
    const pids = matchPids(it);
    if (!pids.length) throw new Error('未找到该项目的运行中进程');
    await ps(pids.map(p => `taskkill /PID ${p} /T /F 2>&1 | Out-Null`).join('; ') + '; $LASTEXITCODE = 0');
    return { ok: true, msg: `已停止 ${pids.length} 个进程：${body.name}` };
  }
  if (op === 'delete') {
    const s = body.source;
    if ((s === 'task' || s === 'service') && cfg.advanced !== true)
      throw new Error('永久删除计划任务/服务属于高危操作：请先在配置文件的 advanced 字段开启高级模式（' + CONFIG_FILE + '）');
    if (s === 'run-user' || s === 'run-machine') {
      const key = s === 'run-machine' ? RUN_KEY_HKLM : RUN_KEY;
      const cur = await ps(`if(Test-Path ${q(key)}){ (Get-Item ${q(key)}).GetValue(${q(body.name)}) }`);
      const val = cur.trim();
      if (!val) throw new Error('注册表中找不到该值');
      cfg.disabledRun = cfg.disabledRun || {};
      cfg.disabledRun[`${s}|${body.name}`] = val;
      saveConfig(cfg);
      await ps(`Remove-ItemProperty -Path ${q(key)} -Name ${q(body.name)} -Force`);
      return { ok: true, msg: `已删除自启项（已备份，可在列表恢复）：${body.name}` };
    }
    if (s === 'startup-folder' || s === 'startup-folder-common') {
      const dir = s === 'startup-folder' ? STARTUP_DIR : process.env.ProgramData + '\\Microsoft\\Windows\\Start Menu\\Programs\\Startup';
      const f = path.join(dir, body.file || body.name);
      if (!existsSync(f)) throw new Error('文件不存在: ' + f);
      await ps(`Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(${q(f)},'OnlyErrorDialogs','SendToRecycleBin')`);
      return { ok: true, msg: `已删除，文件已放入回收站：${body.file || body.name}` };
    }
    if (s === 'startup-folder-off') {
      const f = path.join(STARTUP_OFF, body.file || body.name);
      await ps(`Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(${q(f)},'OnlyErrorDialogs','SendToRecycleBin')`);
      return { ok: true, msg: '已删除（文件在回收站）' };
    }
    if (s === 'run-user-off' || s === 'run-machine-off') {
      cfg.disabledRun = cfg.disabledRun || {};
      delete cfg.disabledRun[`${s.replace('-off', '')}|${body.name}`];
      saveConfig(cfg); return { ok: true, msg: `已删除备份记录：${body.name}` };
    }
    if (s === 'task') {
      await ps(`Unregister-ScheduledTask -TaskName ${q(body.name)} -Confirm:$false`);
      return { ok: true, msg: `已永久删除计划任务：${body.name}` };
    }
    if (s === 'service') {
      await ps(`sc.exe stop ${q(body.name)} | Out-Null; sc.exe delete ${q(body.name)} | Out-Null`);
      return { ok: true, msg: `已删除服务注册：${body.name}（程序文件仍在磁盘）` };
    }
    throw new Error('该来源不支持删除: ' + s);
  }
  if (op === 'relaunch-elevated') {
    const args = [path.join(ROOT, 'server.mjs'), '--takeover', String(process.pid)];
    const spawned = await ps(`Start-Process -FilePath ${q(process.execPath)} -ArgumentList ${args.map(a => q(a)).join(',')} -Verb RunAs -WindowStyle Hidden; "OK"`).then(() => true).catch(() => false);
    if (!spawned) throw new Error('UAC 被取消或提权失败，当前实例继续以普通权限运行');
    setTimeout(() => process.exit(0), 4000);
    return { ok: true, msg: '新实例正在以管理员身份接管端口，3 秒后刷新页面即可。' };
  }
  if (op === 'set-tags') {
    cfg.meta = cfg.meta || {};
    cfg.meta[body.name] = { ...(cfg.meta[body.name] || {}), tags: body.tags };
    saveConfig(cfg); return { ok: true, msg: `标签已更新：${body.name}` };
  }
  if (op === 'save-groups') { cfg.groups = body.groups; saveConfig(cfg); return { ok: true, msg: '分组已保存' }; }
  if (op === 'save-meta') {
    cfg.meta = cfg.meta || {};
    for (const [k, v] of Object.entries(body.meta || {})) cfg.meta[k] = { ...(cfg.meta[k] || {}), ...v };
    saveConfig(cfg); return { ok: true, msg: '分类已保存' };
  }
  throw new Error('未知操作: ' + op);
}

// ---------- HTTP ----------
async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Access-Control-Allow-Origin', '*');
  try {
    if (url.pathname === '/') { res.setHeader('Content-Type', 'text/html; charset=utf-8'); return res.end(readFileSync(UI_FILE, 'utf8')); }
    if (url.pathname === '/api/progress') {
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      return res.end(JSON.stringify(globalThis.PROGRESS));
    }
    if (url.pathname === '/api/state') {
      const data = await (globalThis.__scanP || (globalThis.__scanP = scan().finally(() => { const p = globalThis.__scanP; setTimeout(() => { if (globalThis.__scanP === p) globalThis.__scanP = null; }, 50); })).catch(e => { globalThis.__scanP = null; throw e; }));
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      return res.end(JSON.stringify(data));
    }
    if (url.pathname === '/api/action' && req.method === 'POST') {
      let buf = ''; req.on('data', d => buf += d);
      await new Promise(r => req.on('end', r));
      const r = await actions(JSON.parse(buf || '{}'));
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      return res.end(JSON.stringify(r));
    }
    res.statusCode = 404; res.end('not found');
  } catch (e) {
    res.statusCode = 500; res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error: String(e.message || e).slice(0, 500) }));
  }
}
{
  const ti = process.argv.indexOf('--takeover');
  if (ti > -1) {
    const old = parseInt(process.argv[ti + 1], 10);
    if (old && old !== process.pid) { try { process.kill(old); } catch (e) {} }
    await new Promise(r => setTimeout(r, 700));
  }
}
for (const p of Array.from({ length: 21 }, (_, i) => 28788 + i)) {
  const s = http.createServer(handle);
  try {
    await new Promise((resolve, reject) => { s.once('error', reject); s.listen({ port: p, host: '127.0.0.1', reuseAddr: true }, resolve); });
    console.log('OK windows-autostart-manager http://127.0.0.1:' + p + '/');
    break;
  } catch (e) { s.close(); }
}
