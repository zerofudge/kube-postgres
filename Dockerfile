FROM postgres:9.6

ENV PGDATA=/opt/pgdata

RUN mkdir -p $PGDATA && chown -R 999:999 $PGDATA

COPY docker-entrypoint.sh /usr/local/bin/
