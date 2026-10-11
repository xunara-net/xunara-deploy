# ADR-0034：HTTP / HTTPS 共用入口与 TLS 升级保护

状态：Accepted。日期：2026-10-11。归属：xunara-deploy。
前置提案：[HTTP / HTTPS 共用入口](../proposals/http-https-entry.md)。

## 背景

用户希望两种访问地址共用正式控制中心。原单端口 TLS 站点能跳转 HTTP，但会
对明文 API / POST / 回调进行宽泛重定向，未知 Host 回默认租户。安装器升级
前端时始终覆盖 HTTP 模板且可能忽略 reload 失败，存在 TLS 和自定义路由丢失风险。

## 决策

- 一个 Web / Admin / Core 和数据源；HTTPS 是唯一正式业务入口，不新增明文认证。
- 单端口利用 nginx 497，named location 保留原方法。只有精确 origin 的安全
  GET/HEAD 页面导航可 308 同租户同路径。其余明文请求固定 400、无 Location、
  无会话、无缓存、无入口访问日志、不到达后端；请求内容已明文发送仍无法补救。
- 端口、upstream、证书路径、origin 经严格校验；不猜 Host，不信转发头，不接收
  origin 路径、查询、用户信息或通配符。map hash 设置位于所有 map 之前。
- 唯一生产 renderer 共用原代理模板，并提供自定义站点的入口片段。删除旧复制
  HTTPS server 示例，不保留另一套容易漂移的 locations / 渲染逻辑。
- 安装器 `auto` 默认保留已有配置，新站才用兼容 HTTP 引导模式。显式渲染前
  私有备份并保存权限/归属；同文件系统原子替换、先校验后静态复制、reload/start
  错误返回失败并恢复原配置。静态发布及数据库不是该自动回退范围。

## 备选方案

两套 HTTP/HTTPS 登录：拒绝，明文身份风险与重复产品逻辑不可接受。
全部 497 请求跳转：拒绝，不能保护原请求凭据，也不能把机器协议当页面导航。
未知 Host 固定主域：拒绝，多租户归属混淆；保留原 TLS 站点而只替换入口 guard。
所有前端升级重写站点：拒绝，会丢失 TLS、CA 下载与已有运维定制。

## 影响

仅部署边缘变更，无新数据库迁移、Core API、Identity、Session、Entitlement 或
Headscale Adapter 改动；identity v18 / state v24 / plans v4 保持。HTTPS TS2021 /
Noise / Upgrade 与 DERP 直连保持，中继 TLS / pin 独立。HTTP API/POST 原先会
重定向，现在明确拒绝；正式客户端必须直接配置 HTTPS 并信任测试 CA。
不承诺 HTTP 客户端无感迁移或全 OS 官方客户端连接完成。

## 验证与后续

既有 Deploy CI 增加 16 阶段真实 nginx / 安装器隔离测试：生产 renderer、24 类
非法参数、同端口 TLS、精确租户/IPv4/IPv6/大小写、未知 Host/伪造转发头、方法/
query/认证头/Cookie/Upgrade/请求体/分块传输拒绝、零明文后端请求、HTTPS 方法
保留；安装器保留配置/权限、旧静态清理、校验/重载失败、私有备份与 symlink。
容器内 systemd 调度采用明确 fixture，原站部署另外验证真实 nginx reload 与
上游 Noise，不能混称生产登录/设备连接实测。

本切片不实现完整 Docker TLS、证书自动续期、HSTS、生产公网 CA、自动维护
租户 origin allowlist 或整个商业化平台。实际部署与剩余业务功能在文档台账记录。
