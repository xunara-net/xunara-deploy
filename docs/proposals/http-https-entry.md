# Proposal：HTTP / HTTPS 共用控制中心入口

状态：Accepted，已实现并通过 16 阶段隔离 nginx / 安装器测试。
范围为 Linux systemd 同源站点，不改官方协议或身份模型。
执行记录：[issue #1](https://github.com/xunara-net/xunara-deploy/issues/1)；
决策：[ADR-0034](../adr/ADR-0034-http-https-entry.md)。实际部署证据独立记账。

## 现状与问题

原 HTTPS 测试站已通过 nginx 497 将同端口 HTTP 转为 HTTPS；当前规则没有区分
导航、API、认证回调和 POST。重定向不能补救已经明文发送的凭据，错误 Host
回到默认租户也会混淆网络归属。install-web.sh 则始终覆盖 HTTP 模板，后续升级
可能把已配置的 TLS / 多租户 / 测试 CA location 丢掉，reload 错误还可能被忽略。

## 决策与数据流

1. 同一套 Web / Admin / Core 与数据库，仅 HTTPS 受理正式登录和业务。
   HTTP 仅将明确列入 HTTPS origin allowlist 的无 query GET / HEAD 页面导航
   转到同租户同路径。未知 Host、API / 回调 / 协议路径、写方法、认证头、Cookie、
   Upgrade、CSRF 或请求体拒绝且无 Location，不代转凭据或回到其他租户。
2. nginx 497 转入 named location，保留原方法再判断；不把 POST 内部改成 GET。
   只改边缘入口，HTTPS proxy、Secure Cookie、OAuth redirect URI 与 TS2021 /
   Noise 保持。HTTP 机器客户端不得以浏览器重定向代替 HTTPS 控制面配置。
3. 一个生产 renderer 同时输出原 HTTP 模板、HTTPS 模板及严格入口片段；校验
   端口、upstream、证书路径和显式 origin，防配置注入，不动态信任请求 Host。
4. 安装器默认已有配置就保留；新站用 HTTP 兼容模式，正式公网应显式启用 HTTPS。
   显式重新渲染在改变静态产物前校验 nginx，原配置私有备份与失败恢复，重载
   失败不能报告成功。不承诺整个静态发布或数据库的自动成套回滚。
5. 原站只升级 HTTP guard，保留现有 TLS / locations / 前端 / 控制面 / DERP。
   不登录真实人类账号、不发真实凭据到 HTTP，不更新数据库或重启中继。

## 验证与边界

扩展既有 Deploy CI：真实生产 renderer、nginx -t、同端口 HTTP / HTTPS 请求、
多租户目标、unknown Host、写方法 / query / 私人 API / 回调 / Upgrade 拒绝、
后端零明文请求及没有会话 / 附件；安装器保留配置、错误输入、校验 / reload
失败返回错误并恢复原配置。兼容默认 HTTP 渲染与 Docker 原配置。

无数据库、套餐、Core API 或官方 wire 修改；不开放不安全的第二套登录，
不扩展为完整 Docker TLS、证书自动更新、HSTS、公网 CA 或全 OS 验收。
只读原站检查与真实隔离写入分开记账。后续业务功能仍按独立任务交付。

参考：[nginx 497](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#error_processing)、
[named location](https://nginx.org/en/docs/http/ngx_http_core_module.html#error_page)、
[map](https://nginx.org/en/docs/http/ngx_http_map_module.html)、
[Secure Cookie](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie)。
