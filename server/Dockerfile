# AppDepot server container.
#   docker build -t appdepot ./server
#   docker run -d -p 8080:8080 -v /srv/appdepot:/data appdepot
# /data must contain appdepot.yaml (paths inside it relative to /data) and manifests/.
FROM python:3.12-slim
WORKDIR /app
COPY . /app
RUN pip install --no-cache-dir /app && useradd --system appdepot && mkdir /data && chown appdepot /data
USER appdepot
WORKDIR /data
EXPOSE 8080
ENV APPDEPOT_CONFIG=/data/appdepot.yaml
CMD ["appdepot-server", "serve"]
