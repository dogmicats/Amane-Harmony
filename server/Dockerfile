FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    AMANE_DATA=/amane-data \
    DATA_DIR=/data \
    PORT=8770

WORKDIR /app
# 服务端 2.6.1.92 起拆成了三块（原来是单文件 server.py）：
#   server.py  入口：组装 Handler + main()
#   core/      配置、数据库、路由表、上游请求、图片代理、扩展宿主、业务逻辑
#   api/       16 个端点 mixin（按业务域拆的 Handler 方法）
# 缺任何一块都会启动即 ModuleNotFoundError，所以三层都要 COPY。
COPY server.py extensions.json ./
COPY core/ ./core/
COPY api/ ./api/
COPY ext/ ./ext/

RUN useradd --create-home --uid 10001 amane 2>/dev/null || adduser -D -u 10001 amane; \
    mkdir -p /data && chown -R 10001:10001 /data /app

USER 10001
EXPOSE 8770

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8770/api/user/ping',timeout=3).status==200 else 1)"

CMD ["python", "server.py"]