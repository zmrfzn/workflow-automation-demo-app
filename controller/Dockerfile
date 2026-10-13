FROM docker:27-cli AS dockercli

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1

# Docker CLI and the compose plugin only; the daemon is the host's, via the mounted socket.
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY controller.py entrypoint.sh ./
RUN chmod +x /srv/entrypoint.sh

EXPOSE 5001
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=6 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5001/health', timeout=2)"
ENTRYPOINT ["/srv/entrypoint.sh"]
