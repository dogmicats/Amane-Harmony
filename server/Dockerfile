FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    AMANE_DATA=/amane-data \
    DATA_DIR=/data \
    PORT=8770

WORKDIR /app
COPY server.py subtitles.py ./
COPY subtitle_providers/ ./subtitle_providers/

RUN useradd --create-home --uid 10001 amane 2>/dev/null || adduser -D -u 10001 amane; \
    mkdir -p /data && chown -R 10001:10001 /data /app

USER 10001
EXPOSE 8770

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8770/api/user/ping',timeout=3).status==200 else 1)"

CMD ["python", "server.py"]
