# 2026-10-15 Rust 最小客户端与正式中继 UDP

## What changed

- 新建独立仓库 [xunara-net/xunara-client](https://github.com/xunara-net/xunara-client)，源提交 `47c607ef8f6b14b1c19a6791ffaa33181d7de35d`。
- 发布 [v0.1.0 试用版](https://github.com/xunara-net/xunara-client/releases/tag/v0.1.0)：Linux AMD64 2,791,864 bytes、ARM64 2,314,824 bytes，静态 musl 单文件，附 SHA256SUMS、配置和 systemd 单元。
- 正式中继升级到源提交 `fb190a5d147296811fdc16c49a7b4bcaa800d340`，运行版本 `fb190a5d1472`，启用 `9091/UDP` STUN。
- 本机真实 Binding Request 成功；外部网络探测仍未收到响应，保留 `-stun-unadvertised`，客户端 map 继续 `STUNPort=-1`，不假报公网可用。
- 控制面仍为 `dd158e9`，进程未重启；Web / Admin 未更新，没有执行用户、设备、数据库迁移或快照恢复。

## Why

客户端仅做组网、ACL、UDP 路径发现、DERP 回退和批准后的子网转发 / 可选 SNAT，不携带 GUI、完整业务 Agent 或 Go runtime。正式中继修复 UDP 绑定失败仍继续报告健康的问题，支持本机与公网分别验收。

## Compatibility impact

不修改 TS2021、Noise、WireGuard、Disco、STUN 或 DERP wire。Rust 使用官方底层 Noise/key 固定组件与 BoringTun；首次接入仍通过本账号的预授权密钥或独立浏览器设备审批。

**STUN 是 UDP 打洞，不是 UDP 业务中继。** 本次不宣称已提供官方 Peer Relay、MagicDNS、Exit Node、Tailnet Lock、跨租户共享或移动端客户端。正式公网 TCP DERP 地址、地图、证书 pin 保持。

## Security impact

- 中继身份、私钥、证书及其权限逐文件核对保持一致；地图字节未改变，不重新签发凭据。
- 中继二进制 SHA-256：`3b29207e745e16720f3f8e22ce1f9c1e062025f9fdc160ce368594d0170bfd17`。
- 变更前私有备份：`/root/xunara-rollback/udp-20261015T080413Z`，包含旧二进制、原单元、地图和中继状态。
- 回退只恢复中继二进制 / 单元 / 地图，不能覆盖已有控制面数据库。备份不通过公网提供下载。
- 部署机 INPUT 策略 ACCEPT、无 INPUT 规则及 nft input hook；仍需检查上游公网 UDP 端口转发 / 网络防火墙，不能把 TCP 端口映射当作 UDP 映射。

## 后续启用公网 STUN

1. 映射 / 放行公网 `fakeop4.onbed.cn:9091/UDP` 到部署机 `9091/UDP`。
2. 从外部网络运行新版 `xunara-relay -check-stun fakeop4.onbed.cn:9091`。只有成功后才发布地址。
3. 去掉正式中继单元的 `-stun-unadvertised`，更新地图；当前控制面使用静态地图，须安排加载 / 重启，不能假设文件被自动热加载。

安装器对应配置：`XUNARA_STUN_PORT=9091 XUNARA_STUN_UNADVERTISED=true`。未提供端口、非法端口或非法布尔值会在写系统配置前拒绝。需要 relay `v0.1.0-preview.3` 或源提交 `fb190a5` 及更新版本；缺省 false 保持旧版兼容。

离线预生成地图与服务启动使用同一组 STUN 参数，避免第一份地图错误地启用默认 3478，而运行中的中继关闭 UDP / 使用其他端口。

## Tests

- 客户端 GitHub CI 全绿：`38703669988`；Rust clippy、11 项单测、官方 STUN 编码契约。
- 两台 Rust 节点 + 独立 LAN namespace：加密 TCP/ICMP、ACL 拒绝、审批子网、官方 tsnet 双向互通、禁 UDP 后 pin DERP 回退及恢复。
- Ubuntu 24.04 Docker：无 LAN 回程路由的 SNAT、优雅停止清理、重启身份、同名 nft 表拒绝接管；Go fixture 使用 race 构建，无 race 报告。
- 双架构静态构建 / 校验和；AMD64 在无运行库 chroot 中启动；ARM64 用 QEMU 启动，尚非物理 ARM 网络验收。
- RustSec 对 180 个锁定依赖扫描，无已知漏洞或警告；不代表完成独立安全审计。
- Rust 对正式部署完成 CA 验证 HTTPS + Noise/TS2021 握手，不注册生产设备。
- Relay `go build/vet/test/test -race` 与隔离安装测试通过，源提交 CI `38702667270` 全绿。
- 本机 STUN、正式 HTTPS health、控制面 PID、地图和中继私有文件复核通过；公网 UDP 尚未通过，明确保留为未广播状态。
