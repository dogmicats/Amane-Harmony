"""服务端内部包（2.6.1.87 起）。

`server.py` 原来是 9900 行单文件，按职责拆成：

    core/   配置、数据库连接、HTTP 框架、扩展宿主、文本工具 —— 不依赖业务
    api/    HTTP 端点（按业务域拆 mixin，Handler 继承它们）
    server.py  只剩入口：VERSION + 组装 + main()

拆的原则是**入口名不变**：依然 `python3 server.py`，容器 command、部署脚本、
`deploy_dev.sh`、`docker-compose.yml` 一律不动。
"""
