# 2026-10-16 demo 设备确认接入失败修复

## What changed

- 站点：`https://fakeop4.onbed.cn:9090`。
- `11:26:03 UTC`，先一致性备份套餐库和 demo 租户库，再通过现有平台接口，
  把 demo 默认网段从 `100.100.0.0/24` 重新自动分配为 `100.100.27.0/24`。
  期望和实际分配版本均为 2；保留旧网段预留，Free 套餐未变。
- `11:42:33 UTC`，服务端从 `0663e14` 升级为 `fabf099`，Web 从 `dce6ef3`
  升级为 `0fc2a38`。已知地址池耗尽明确返回 `ADDRESS_POOL_EXHAUSTED`，
  浏览器显示中文恢复建议，不再只显示 `could not record the decision`。
- 不替用户批准或拒绝设备，不重置密码、不迁移设备、不变更其他租户网段。

## Why

服务日志明确为 `state: IPv4 space exhausted`。demo 当时设备数为 0，
问题不是达到 10 台套餐额度，也不是会话或 CSRF 被拒绝。

历史 `system:import` 记录保留了 `100.100.0.0/24`，但这个范围已被当前
`netspace.ClientReserved()` 排除，整池无可分配地址。新租户分配已经跳过
这些范围，却不会自动覆盖用户的历史网段。此前审批和预授权接入没有准确分类
该错误，分别表现为笼统 500 或存储故障。

恢复步骤和完整边界见服务端
[`device-address-pool-recovery.md`](https://github.com/xunara-net/xunara-server/blob/fabf099/docs/device-address-pool-recovery.md)。

## Compatibility impact

- TS2021、Noise、Register/Map 字段、机器/节点身份、官方客户端轮询不变。
  浏览器/v2 已知配置冲突改为 409；机器注册仍使用标准 `RegisterResponse.Error`。
- 无迁移，保留现有设备 IP、待审批记录、套餐和历史地址预留。没有静默改写
  所有历史租户网段的自动迁移，也不把自动分配回退到入口用户。
- 发布后活动租户合计 7 个用户、4 台设备，均与发布前一致；demo 为 1 用户、
  0 台已批准设备。实际接入仍需要用户在客户端重新发起并明确确认。
- 只读核查全部活动租户，当前默认池没有与项目保留段重叠；排除归档目录。
- `/key?v=130` 原始响应 SHA-256 保持
  `d5dc453829d60c247445bd41799aa73bd46bd0c2f55ef35b38e030d0cf9cd720`。

## Security impact

- 地址耗尽时，节点、授权、一次性密钥、必需审计和通知版本整体回滚；修复后
  仍需要明确审批，不连续自动重试，不放宽租户或权限边界。
- 管理凭据仅从受限环境文件读取并放请求头；没有出现在 URL、命令参数、
  日志或仓库中。备份为 root-only，数据库快照权限 0600。
- 本次应用发布没有修改数据库、nginx、TLS 配置或组织/环境文件。nginx 配置
  SHA-256 仍为 `361d28e0fcdc5ff643d55e8878acaa68c756d556ea9505bb69518eec402aba4b`。
  组织文件保持 `0640 root:xunara`，环境文件保持 `0600 root:root`。
- 正式证书保持，nginx 未 reload；relay MainPID `180187` 未重启，9091 未变。

## Tests

- 新增回归先复现旧 500/503，再验证类型化冲突及原申请可恢复审批。
- `go build ./...`、`go vet ./...`、`go test ./... -count=1` 通过。
- `go test -race ./... -count=1 -timeout=30m` 通过，control 约 719 秒。
- 旧导入池 → 浏览器/v2 409 → 平台重新分配 → 明确审批 → 真实 Noise follow-up
  成功；同时验证套餐、他租户、历史预留、幂等和精确机器身份。
- IPv4/IPv6 池耗尽均不消耗单次接入密钥或留下部分节点/审计/通知。
- 分享官方客户端集成 race、Rust Go 兼容夹具 build/vet/test、Staticcheck 通过。
- Web 525 单测、类型检查和构建通过；隔离 daemon 的授权浏览器 9 阶段、
  共享控制台 19 阶段通过。前端 409 分支为受控注入，不冒充生产设备审批。
- 生产经 SSH 纯 TCP 转发访问原 nginx，保留规范域名、Host/SNI 和正常 TLS
  验证；不是独立公网网络探测。版本、实际发布的中文提示、匿名详情 401、
  320/390/768/1440px 布局验证通过，JavaScript 异常 0，设备决定数 0。
- xunarad、nginx、relay 均 active；发布后检查窗口无新增设备分配/审批错误。
- Web GitHub CI `38894852117` 已通过；server `38895502805` 已触发，记录时
  尚在运行。完整 Go 和竞态通过结果为本地已完成结果。

## 备份与回滚

- 数据修复前一致性备份：`/root/xunara-rollback/demo-address-pool-20261016T112603Z`。
- 应用发布备份：`/root/xunara-rollback/address-pool-20261016T114233Z`。
- 常规回滚仅恢复二进制和 Web，不恢复数据库快照、不覆盖发布后新授权或用户操作。
  数据配置修复独立于应用发布，回滚应用也保留已修正的 demo 网段。
- 二进制 SHA-256：
  `bff10b6280062a27934eb587f96d10d83805cccdbed27c962cd990fe15db92a2`。
- Web 包 SHA-256：
  `be50a97a7f45890907246d95d94543a1b92e93ebc99f83e32843ae77573e2ff2`。
