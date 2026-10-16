# 2026-10-16 全部旧浏览器界面退役上线

## What changed

- 站点：`https://fakeop4.onbed.cn:9090`。
- 服务端从 `87f70d5` 升级到 `0663e14`；用户 Web 为 `dce6ef3`，
  基础迁移提交 `da44509`；后台验收脚本为 `b870d3d`（后台 UI 不另行重做）。
- 部署模板与真实 nginx 回归提交 `fdacd12`。现有双 TLS server 保留证书、
  SNI、HTTP origin allowlist 与同端口明文拒绝规则，仅迁移浏览器分流。
- 全部 Go HTML 模板、旧页脚/CSS/翻译、内嵌 WebAuthn、旧平台后台表单及其
  专属会话代码已删除；不是只换版本号或隐藏旧导航。
- 设备/SSH 授权、共享设备账户登录、初始化与认证错误均由独立 Web 渲染，
  通过 JSON API 读取持久状态和提交明确确认。所有旧表单写请求拒绝。

## Why

用户反馈的 `Xunara 87f70d5` 确实来自运行二进制的独立授权模板，不是缓存。
先前仅删除完整 `/console`，仍保留初始化、设备批准、SSH、错误和内嵌后台，
加上 nginx 继续反代这些浏览器路径，导致新旧界面混用。本次一起清理。

源代码核查与保留边界见服务端的
[`browser-interface-audit.md`](https://github.com/xunara-net/xunara-server/blob/0663e14/docs/browser-interface-audit.md)
和 [ADR-0050](https://github.com/xunara-net/xunara-server/blob/0663e14/docs/adr/ADR-0050-browser-ui-retirement.md)。

## Compatibility impact

- 官方客户端 `AuthURL` 与原设备授权 URL 保持不变，用户反馈的原地址已在
  真实浏览器重验为新版页面。TS2021/Noise/Register/Map/SSH 协议未修改。
- 租户 API/Cookie、统一账户登录和第三方回调边界保持；保留 Rust Go 兼容夹具
  使用的 `Server.SetAddressPrefix`，不能误当作旧界面删除。
- 无数据库迁移，不清空状态库或覆盖组织/环境文件；没有新增生产测试账户，
  没有替用户批准、移动或删除设备。不回滚用户自行操作。
- 初次只读预检和部署后设备数量有差异：持久审计显示既有用户在
  `10:15:28 UTC` 执行 `node.deleted`，早于本次发布的 `10:42:33 UTC`。
  该用户操作未被恢复；部署后现存账户总数 7、设备总数 4。
- `xunara-relay` 始终为 active，MainPID `180187` 未重启，9091 配置未改变。
- `/key?v=130` 原始响应 SHA-256 保持
  `d5dc453829d60c247445bd41799aa73bd46bd0c2f55ef35b38e030d0cf9cd720`。

## Security impact

- 浏览器设备/SSH 决定只接受人类会话和头部 CSRF；服务密钥不冒充人类。
- 旧登录、初始化、注册、退出、设备/SSH、passkey 及后台表单实测 410，
  代理层不再把它们转发执行。匿名设备/SSH JSON 读取为 401。
- 登录/注册拒绝普通表单伪装 JSON。先以真实可解码的 `text/plain` 正文
  复现旧登录签发 Cookie（200），再验证新实现 415、无 Cookie、无新会话；
  合法 JSON 和 UTF-8 charset 仍能登录。
- 回调失败仅传固定原因码，原始提供方错误不进页面；原型属性原因参数拒绝。
- 页面读取/写入故障不伪造成功，结果未知必须先刷新，不自动重复批准。
- 生产浏览器使用正常证书验证，未启用 `ignoreHTTPSErrors` 或全局忽略证书参数。
- 组织文件仍为 `0640 root:xunara`，环境文件仍为 `0600 root:root`；
  发布脚本验证二者未改变。不在记录中保存管理令牌、密码、私钥或授权链接 ID。

## Tests

本地最终代码：

- `go build ./...`、`go vet ./...`、`go test ./... -count=1` 全通过。
- `go test -race ./... -count=1 -timeout=30m` 全通过，
  control 包约 719 秒、identity 包约 150 秒。
- Staticcheck `U1000,SA4006` 全通过；新增 Core 无模板源码保护与旧 POST 零副作用测试。
- 官方客户端分享集成 `go test -race . -count=1 -timeout=4m` 通过；
  Rust 客户端 Go 兼容夹具 `build/vet/test` 编译验证通过。
- Web 524 单测、admin 61 单测、两前端类型检查/构建通过。
- 真实 daemon 浏览器：授权 8 阶段、完整管理 103 阶段、登录配置/账户 25 阶段、
  共享控制台 19 阶段、设备分享 6 阶段；网络检查器 17 项通过。
- 真实 Docker nginx 24 阶段通过，TLS 验证启用、明文后端请求数 0；
  生产候选双证书站点先经独立 `nginx -t`，安装后再次检查并 reload。

生产只读验收：

- 实际 `/version` 为 `0663e14`。
- 原设备授权、租户授权、SSH 检查、共享登录、初始化和错误页均加载新 Web；
  浏览器页无旧表单、旧页脚，HTML 禁缓存。
- 320/390/768/1440px 均无横向溢出；JavaScript 异常 0。
- 旧浏览器表单/后台提交 410，匿名批准读取 401，普通表单伪装登录 415。
- nginx、xunarad、relay 均 active；正式证书验证通过。

GitHub：Web `38887978593`、admin `38886854223`、部署模板 `38886856955`
CI 已通过；服务端 `38888925051` 已触发，发布时仍在运行。上面的全量及竞态
结果为本地已完成结果，不把尚在运行的远程 CI 记为通过。

## 回滚与产物

受限备份：`/root/xunara-rollback/browser-ui-20261016T104233Z`。
仅保留回滚所需的旧二进制、Web 与代理配置，不作为第二套站点提供。
失败恢复只还原这些应用文件，不能覆盖正在使用的数据库或恢复用户删除的设备。

- 二进制 SHA-256：
  `56c048f4919da0dfbd83d0e55034235dc99fa4cd57d42a928e5686709e86bfbc`
- Web 包 SHA-256：
  `a607eef8e573f73d4ade056086b163eddfb57f6be60615b6b51ef60cf6819703`
- 生产 nginx 候选 SHA-256：
  `361d28e0fcdc5ff643d55e8878acaa68c756d556ea9505bb69518eec402aba4b`
