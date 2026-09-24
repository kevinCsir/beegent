---
name: beegent-lan-relay
description: 为 Windows、Linux、macOS 上的 WorkSwarm 开启、查询或关闭 beegent 手机局域网连接，使用现有 Node.js 转发 WebSocket 与 HTTP 下载端口，无需修改 WorkSwarm 或安装 npm 包。
---

# beegent 手机局域网连接（Node 版）

用户要求开启手机连接、查询转发状态或关闭连接时使用。多文件版使用同目录下的 scripts/lan_relay.cjs；单文件版在文末附有相同脚本的全部代码。仅保存或导入文档不会启动服务。

## 工作方式

使用一个 Node.js 后台进程进行 TCP 双向转发：

```text
手机 → 电脑局域网 IP:29000 → 127.0.0.1:19000  WebSocket 消息
手机 → 电脑局域网 IP:25173 → 127.0.0.1:5173   HTTP 附件下载
```

默认绑定 `0.0.0.0`，手机填写电脑实际局域网 IP。TCP 转发保留 HTTP、WebSocket 原始字节，不解析、重写或存储对话和附件。日志仅记录连接、错误和字节数。

所有系统只需 **Node.js 18 或更新版本**，无需 Python、npm install、第三方包或编译。Windows/macOS 优先复用桌面版随附 Node；Linux 或其他安装形式需要检查现有 Node，不能承诺每一种发行方式都自带运行时。没有可用 Node 时说明缺少运行环境，不擅自下载安装。

本脚本不开启公网穿透，不新增手机侧鉴权，不修改 Swarm 配置，不注册开机自启。`0.0.0.0` 包含其他网卡接口，需要限定网卡时可指定实际 IPv4。局域网访问范围仍受系统防火墙约束。

## 保存脚本

若已取得多文件 Skill，可直接使用其中的 `scripts/lan_relay.cjs`，将下面的目录变量设为实际 Skill 目录；也可以完整复制到建议目录。若收到的是单文件 Markdown，把文末「完整代码：scripts/lan_relay.cjs」的完整 JavaScript 代码块保存为 `scripts/lan_relay.cjs`。不要把 Markdown 围栏写进文件，不要截断、省略或改名为 `.js`。

Windows 保存目录：

```powershell
$skillDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'beegent\lan-relay-skill'
New-Item -ItemType Directory -Force -Path (Join-Path $skillDir 'scripts') | Out-Null
$relayScript = Join-Path $skillDir 'scripts\lan_relay.cjs'
```

Linux 保存目录：

```bash
skill_dir="$HOME/.local/share/beegent/lan-relay-skill"
mkdir -p "$skill_dir/scripts"
relay_script="$skill_dir/scripts/lan_relay.cjs"
```

macOS 保存目录：

```bash
skill_dir="$HOME/Library/Application Support/beegent/lan-relay-skill"
mkdir -p "$skill_dir/scripts"
relay_script="$skill_dir/scripts/lan_relay.cjs"
```

优先通过文件写入工具原样保存 UTF-8。使用 shell 写入时，PowerShell 使用单引号 here-string，Unix 使用单引号分隔符 here-document，避免变量和反引号提前展开。

本版本只使用这一个 `.cjs` 文件，旧版 `lan_relay.py`、`manage.ps1`、`manage_posix.py` 不再参与执行。升级前检查是否有旧版转发占用端口；需要切换时先用旧版管理器停止旧实例。新版 `stop` 只管理新版进程，不会自动终止旧版 Python 或用户手动启动的其他代理。

## 找到 Node

### Windows

先定位正在使用的桌面程序安装目录，可从进程可执行文件路径、快捷方式或安装记录读取。若桌面程序位于 `<安装目录>\jiuwenswarm.exe`，优先检查 `<安装目录>\runtime\node-runtime\node.exe`。不要将桌面程序自身当成 Node。

下面是默认安装目录的候选检查；未命中时先按实际安装位置查找，再使用系统 Node。不要写死用户名。

```powershell
$nodeExe = $null
$bundledNode = Join-Path $env:ProgramFiles 'JiuwenSwarm\runtime\node-runtime\node.exe'
if (Test-Path -LiteralPath $bundledNode) {
  $nodeExe = $bundledNode
} else {
  $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($systemNode) { $nodeExe = $systemNode.Source }
}
if (-not $nodeExe) { throw '未找到 Node，请检查桌面版实际安装目录中的 runtime\node-runtime\node.exe' }
& $nodeExe --version
```

自定义安装目录时将 `$nodeExe` 设为已确认的 Node 绝对路径。验证版本至少为 18。

### macOS

从正在使用的桌面 App 确认实际 `.app` 位置和名称；源码打包结构中的 Node 位于 `<实际应用>.app/Contents/Resources/node-runtime/bin/node`。不要假设所有版本都采用同一个 App 名称。若未随附 Node，再检查已有系统 Node。

### Linux / 系统 Node

```bash
node_bin="$(command -v node)"
if [ -z "$node_bin" ]; then
  printf '%s\n' '未找到系统 Node，请检查桌面安装目录中的内置 Node。'
else
  "$node_bin" --version
fi
```

如果采用内置 Node，将 `node_bin` 设置为已确认的绝对路径，再读取版本。不需要 `sudo`、`nohup`、`setsid` 或脚本执行权限。

## 启动前确认端口

1. 确认桌面版已启动、后端服务已就绪。
2. 结合本次桌面启动日志、监听端口和进程归属确认 **WebChannel** 与 **HTTP 下载服务** 的实际端口，通常为 `19000`、`5173`。桌面版可能自动换端口；不要把 `18092` 或 `19001` 当成手机消息端口。多个实例不能辨别时请用户选择。
3. 检查对外端口 `29000`、`25173` 是否空闲。被占用时先识别进程，不关闭桌面后端、不批量结束 Node/Python 进程。

| 系统 | 监听端口及进程 | 网卡地址 |
| --- | --- | --- |
| Windows | `Get-NetTCPConnection -State Listen`，结合 OwningProcess 查询进程 | `Get-NetIPAddress -AddressFamily IPv4` |
| Linux | `ss -ltnp`，或已有的 lsof | `ip -4 addr show` |
| macOS | `lsof -nP -iTCP -sTCP:LISTEN` | `ifconfig`，必要时结合 `networksetup -listallhardwareports` |

工具缺失或权限不足时使用已有工具或日志，不自动安装、提权。不要在 macOS 写死 `en0`。

## 启动、查询、停止

先执行 `status`。已运行且配置满足要求时复用；需要修改参数时告知连接会中断，再按用户的变更要求停止并重启。

Windows：按用户请求执行对应命令，不要连续启动后立即停止。

```powershell
& $nodeExe $relayScript status
& $nodeExe $relayScript start --listen-host 0.0.0.0 --message-port 29000 --file-port 25173 --backend-port 19000 --download-port 5173
& $nodeExe $relayScript stop
```

Linux / macOS：

```bash
"$node_bin" "$relay_script" status
"$node_bin" "$relay_script" start --listen-host 0.0.0.0 --message-port 29000 --file-port 25173 --backend-port 19000 --download-port 5173
"$node_bin" "$relay_script" stop
```

脚本的 `start` 已用 Node `spawn` 创建脱离终端的后台子进程，Windows 使用 `windowsHide: true`。无需再用 `Start-Process` 包裹，这样可以直接读取退出码与启动结果。不要直接执行内部 `run` 命令。

启动必须同时绑定两个转发端口，并收到新进程的状态响应才报告 `ready: true`。任一端口绑定失败会关闭本次已绑定的端口并退出。成功代表转发服务就绪，**不代表后端目标端口可用、模型正常或手机已经连接成功**。脚本不会主动向 Swarm 发送业务请求。

默认最多接入 128 个转发 TCP 连接，可在 `start` 时用 `--max-connections` 调整；消息和下载共同计数。上游 TCP 建连超时为 5 秒；正常 WS 不设置空闲超时。`pipe` 提供流量背压，并允许 TCP 半关闭时继续接收另一方向的数据。

`status` 和 `stop` 不接收端口参数，读取本用户已登记实例。`status` 返回实际配置、PID、当前连接数和日志位置。对已运行实例再次 `start` 不会悄悄替换配置，会返回 `reused` 和 `requestedConfigMatches`。

### 精确停止与状态文件

脚本另外监听一个 **仅限 `127.0.0.1` 的随机控制端口**，用于状态查询和停止，不填入手机。每次启动随机生成控制凭证和实例编号，存入当前用户状态文件；命令通过凭证及实例身份核验后，由转发进程关闭自身监听器和现有连接。无需按进程名执行 kill。

每个系统用户管理一个本脚本实例。不要使用 `taskkill /IM node.exe`、`pkill node`，也不要只凭旧 PID 结束进程。不要将包含控制凭证的 `state.json` 原文发给用户或写进聊天日志。

状态/日志目录：

- Windows：`%LOCALAPPDATA%\beegent\lan-relay-node`。
- Linux：`${XDG_STATE_HOME:-$HOME/.local/state}/beegent/lan-relay-node`，只接受绝对的 XDG_STATE_HOME。
- macOS：`~/Library/Application Support/beegent/lan-relay-node`。

目录中仅保存进程管理状态与连接日志，不保存会话消息。`relay.log` 每份约 4 MiB，保留两个轮转备份。Unix 创建目录权限为 0700、状态文件为 0600；Windows 使用用户目录继承权限。

管理命令用 `operation.lock` 目录避免并发启动/停止。若提示锁存在，先查看 `operation.lock/owner.json` 并核对对应管理进程；运行中就等待，只有确认管理命令已经退出才删除该锁目录的已知文件和空目录后重试。不要按超时时长直接清锁。

控制连接失败而记录的 PID 仍存在时，脚本保留状态并拒绝启动/停止，需人工核对进程身份和日志；进程异常退出且 PID 不存在时，下次 `start` 才会清理遗留状态。遇到 PID 被复用，确认旧实例已退出后可人工移除遗留状态文件，不能终止复用该 PID 的进程。

## 向用户提供连接信息

读取电脑网卡，选择与手机同网的 Wi-Fi/以太网 IPv4，排除回环、断开的网卡和 VPN/WSL 等虚拟接口。不确定时列出候选让用户选择。

返回电脑实际 IP、对外消息端口、对外下载端口、后台状态及日志位置。例如手机填写 `电脑局域网IP / 29000 / 25173`；不要填 `0.0.0.0`、`127.0.0.1` 或随机控制端口。

后台进程可能被沙箱、外部会话管理器或操作系统终止。不得把命令已提交说成已持续运行，也不得在用户验证前声称对话或下载成功。休眠、网络切换、系统重启后手机可能需重新连接；电脑重启后需重新启动转发。后端目标端口变化时必须停止并用新参数启动。

## 排查边界

- `EADDRINUSE`：检查端口占用归属，不批量结束进程。
- `ECONNREFUSED` / 上游超时：检查桌面服务状态及实际后端端口。
- 转发就绪但手机无法连入：确认同网、热点/AP 客户端隔离和防火墙对 **Node** 入站的许可；监听 `0.0.0.0` 不会绕过防火墙。如需放行，仅针对本次两个转发端口及实际局域网范围，按当前权限执行，不关闭整机防火墙或自动提权。
- 文件接口返回 HTTP 错误：TCP 转发不会补齐下载令牌、修复路径或改写 URL，应检查后端响应及手机的下载端口配置。
- 日志写入失败或状态文件异常：按返回路径检查用户目录权限，勿通过管理员运行掩盖原因。

不要主动运行自动测试、截图或发送对话任务。用户请求开启/关闭时执行对应管理命令及必要的状态检查即可。
