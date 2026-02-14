FROM influxdb:2.7

RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*

COPY init-influxdb.sh /init-influxdb.sh
RUN chmod +x /init-influxdb.sh

ENTRYPOINT ["/init-influxdb.sh"]