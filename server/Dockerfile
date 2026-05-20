FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DUKE_HOST=0.0.0.0 \
    DUKE_PORT=8765 \
    DUKE_TLS=1 \
    DUKE_CERT_DIR=/data/certs

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY duke_server ./duke_server
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x entrypoint.sh

VOLUME ["/data/certs"]
EXPOSE 8765

ENTRYPOINT ["./entrypoint.sh"]
