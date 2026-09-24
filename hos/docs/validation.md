# 验证记录 · 2026-09-23

工程：JiuWenBridge，main（尚无提交），工作区版本 0.1.0。
环境：DevEco Studio 6.1.1.290 / Hvigor 6.24.3 / API 24。
设备：FMR0223926049133，包名 com.kevincsir.jiuwenbridge。
服务端：本地 JiuwenSwarm，核对版本 e829cd8bf86bbe7a3b0a4004709677f272c2e5e1。

## 本次验证

| 项目 | 结果 | 范围 |
| --- | --- | --- |
| core.test.cjs | PASS | 请求关联、断线、批量流式更新、多会话、停止等原有核心行为 |
| queue-mode.test.cjs | PASS | 八种模式参数、独立队列、编辑排序、运行时 ACK、补充边界、旧片段隔离、跨会话自动发送、停止暂停、拒绝/断线不重发 |
| transport.test.cjs | PASS | 模拟鸿蒙 API，发起连接成功不提前显示已连接；必须等 open，握手前失败/关闭会拒绝 |
| queue-mode-build-02 | PASS | ArkTS 编译及 HAP 签名，有原有 API 提示和 AlertDialog 弃用警告，无编译错误 |
| queue-mode-live-01 | PASS | 真实后端创建全部八种模式并读取元数据核对；Agent Work Normal 的补充接收、消息边界、停止和队列自动发送 |
| queue-mode-install-02 | PASS | 覆盖安装、启动与 PID 确认，未清除应用数据 |
| queue-mode-device-modes-02 | PASS | 真机三维选项操作，创建 Team Code Plan 和 Agent Work Normal；通过临时 USB 转发连接真实 Swarm |
| queue-mode-device-queue-01 | PASS | 真机执行中输入、排队、补充当前任务和停止；通过临时 USB 转发连接真实 Swarm |
| 当前热点 LAN 直连 | BLOCKED | 默认地址 192.168.43.217，实测电脑 WLAN 已变回 7.249.55.194；手机对默认地址 ping 丢包，首次模式用例失败 |
| 完整 Team/Code/Plan 任务与审批 UI | NOT_RUN | 八模式创建已验证；本次没有声称全部模式完整任务通过，审批/丰富消息属后续阶段 |
| 性能量化、持久化、重连同步 | NOT_RUN | 未采样帧率；当前仍为内存队列和消息缓存 |

证据目录：`%LOCALAPPDATA%\JiuWenBridge\test-runs`，子目录见上表。
真机截图在各 device 用例的 `evidence` 下；模式选项为 `mode-picker.png`，队列为 `queue-visible.png`。
首次 LAN 失败记录保留在 `queue-mode-device-modes-01`，不以 USB 验证替代 LAN 结论。
验证结束恢复输入框默认 LAN 地址，移除本次临时 USB 转发；不修改电脑防火墙或 Swarm 源码。

签名产物：`entry/build/default/outputs/default/entry-default-signed.hap`

SHA256：`707B818993F70BE532167CC8E675F6FCD7ECA7738AC0D966C4512DD7A714F203`

## 交互约定

- 新建会话选择 role / profile / style，保存每个 session 的规范模式；创建和后续发送均携带 mode、work_mode。
- 执行中发送先进入该会话的本地队列，任务结束且队列未暂停时取出一条发送。
- 单 Agent 的补充绑定当前 execution_id，并等待 runtime.accepted；Team 不显示此操作。
- 用户补充气泡按 chat.input_received 边界加入；旧输出阶段不会覆盖新阶段气泡。
- 停止、断线或补充失败暂停队列。发送结果未知不自动重试，明确失败可由用户重新排队。
- 队列仅驻留内存，退出不恢复；Plan 审批和丰富 Team 消息仍需电脑端处理。
