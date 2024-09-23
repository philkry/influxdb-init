FROM influxdb:2.7

COPY init-influxdb.sh /init-influxdb.sh
RUN chmod +x /init-influxdb.sh

ENTRYPOINT ["/init-influxdb.sh"]