FROM python:3.12-slim

# One source, two images: build with --build-arg RELEASE=v1 or RELEASE=v2.
ARG RELEASE=v1
ENV APP_RELEASE=${RELEASE} \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chmod +x /app/entrypoint.sh

EXPOSE 5000
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=6 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2)"
ENTRYPOINT ["/app/entrypoint.sh"]
