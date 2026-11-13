# Security policy

## 报告漏洞

请通过 GitHub Security Advisories（本仓库 "Security → Report a vulnerability"）私下报告，不要在公开 Issue 里贴细节。

## 使用上的安全边界

- 播放与字幕端点把 token 放在 URL query 中（为绕开 mpv-arkts 的请求头缺陷）。**请只在 HTTPS 或可信内网使用**；反向代理不要记录 query，token 应定期轮换。
- `amane-user` 不设独立鉴权，沿用 Amane 的 token。不要把它直接暴露到公网，务必放在反代之后。
- 图片代理有主机白名单；`IMG_HOST_ALLOW_EXTRA` 只填你信任的主机，否则端口可能变成任意 URL 代理。
- 媒体卷默认以只读方式挂载；为让在线字幕直接落到影片目录而改成可写时，旁挂只会写它自己下载的字幕文件，删除也只限自己登记过的那些。
- 在线字幕搜索只接公开、无需账号的来源；本仓库不接受、也不需要任何第三方 API key。

## 脱敏自检

维护者推送前应运行 `python tools/scan_secrets.py --path .`，要求 0 命中；CI 的 `secret-scan` workflow 会在每次 push / PR 复跑。
