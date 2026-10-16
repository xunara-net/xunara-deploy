# 2026-10-16：线上内嵌用户中心退役

## 发布范围

- 站点：`https://fakeop4.onbed.cn:9090`；服务端 `87f70d5`、Web `de6f1d9`、部署模板 `718f33e`。
- 旧页面实际来自当前服务端的 `/console/*` 挂载，不是浏览器缓存或旧 dist；本次删除整套旧页面和表单处理器。
- 实际 nginx 保留原有两个 HTTPS server、Host allowlist、正式 / 测试证书与 CA 下载，只补充退役入口及 `/ui/prefs` 代理。
- 回滚备份：`/root/xunara-rollback/console-20261016T080324Z`。仅备份 / 恢复二进制、Web 与 nginx，不覆盖活跃数据库。

## 线上验收

- GET / HEAD `/console/ssh-check`：302 到 `/login?return_to=%2Fsecurity%23ssh-check`，不再渲染旧页面。
- `/t/gggg/console/ssh-check`：统一登录，回跳仍在该网络的 `/security#ssh-check`；未知租户旧路径 404，不回落至 SPA。
- 旧控制台 POST（包括通行密钥旧别名）返回 410；新 SSH 记录 API 未登录返回 401。
- 新登录页、独立 `/admin/` 正常；390px 真实浏览器验收无横向溢出，无旧中心页脚 / 登录范围 / 网络标识。
- 使用真实站点 HTTPS 与正式证书验证，没有跳过证书校验；因调试端直连受限，通过 SSH 转发保持原 Host / SNI / 端口访问同一 nginx。
- 发布前后活跃数据库合计 7 个账户、6 台设备不变；客户端 `/key?v=130` 公钥响应摘要不变。
- nginx、xunarad、中继均 active；中继 PID `180187` 未变化，不重启或重配 9091 / UDP。
- 未提交任何真实用户密码、创建生产测试账户、批准设备或改变归属。旧浏览器授权及其安全校验由原控制面保留。

## 构建追溯

- 服务端二进制 SHA-256：`0c2bfa24f6d23106514e5c031dbcb314786463962882e6759cb76d08da355d18`。
- Web 入口 SHA-256：`bc371f105d36f46e9cd6c70d772029e9e7b07444281320cbdea2c62a5a06eea5`。
- 本地 build / vet / Staticcheck、全量普通测试、完整 `go test -race ./... -timeout=30m` 均通过；
  Control 包竞态耗时 727 秒，默认十分钟不足。针对退役 / 账户 / 租户 / SSH 的竞态与官方客户端分享竞态回归也通过。
- Web 506 项单测、19 阶段共享控制台浏览器回归、6 阶段设备分享浏览器回归通过；真实隔离 nginx 22 阶段通过。
- [服务端 CI](https://github.com/xunara-net/xunara-server/actions/runs/38870893230)执行完整 `-race`（包级 30 分钟预算）；
  [Web CI](https://github.com/xunara-net/xunara-web/actions/runs/38870551870)、
  [部署模板 CI](https://github.com/xunara-net/xunara-deploy/actions/runs/38870552640)提供独立记录，不把浏览器夹具当作生产数据面验收。

## 边界

用户中心以独立 Web 为唯一实现；初始化、设备批准和 SSH 批准所需的独立 HTML 页面不是旧控制台。
没有新增数据库迁移或改动官方客户端协议。旧中心中尚未迁入新 Web 的非核心模块仍只提供已有 API / CLI，
不以退役旧页面为名宣称全功能已完成；以服务端 ADR-0049 为准。
