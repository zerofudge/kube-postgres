#!/usr/bin/env bash
set -Eeo pipefail
# TODO swap to -Eeuo pipefail above (after handling all potentially-unset variables)

### NB: from: https://raw.githubusercontent.com/docker-library/postgres/040949af1595f49f2242f6d1f9c42fb042b3eaed/9.6/docker-entrypoint.sh

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [[ "${!var:-}" ]] && [[ "${!fileVar:-}" ]]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [[ "${!var:-}" ]]; then
		val="${!var}"
	elif [[ "${!fileVar:-}" ]]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

if [[ ${KUBERNETES_PORT} && $(id -u) = 0 ]]; then
    LOWR='/mnt/db-lower'
    UPPR='/mnt/db-upper'
    MNT=$(dirname ${PGDATA})

    if [[ -d ${LOWR} || -d ${UPPR} ]]; then
        [[ ! -d ${LOWR} ]] && \
            mkdir -p ${LOWR} &&
            mv ${MNT}/* ${LOWR}

        [[ ! -d ${UPPR} ]] && \
            mkdir -p ${UPPR} && \
            mount -t tmpfs tmpfs ${UPPR}

        rm -rf ${MNT}
        mkdir -p ${UPPR}/{upper,work} ${MNT}
        chown -R postgres: ${UPPR}/{upper,work}

        mount -t overlay overlay -o lowerdir=${LOWR},upperdir=${UPPR}/upper,workdir=${UPPR}/work ${MNT}
        echo "INFO: created OverlayFS for ${MNT}"
    fi
fi

if [[ "${1:0:1}" = '-' ]]; then
	set -- postgres "$@"
fi

# allow the container to be started with `--user`
if [[ "$1" = 'postgres' ]] && [[ "$(id -u)" = '0' ]]; then
    [[ ! -d ${PGDATA} ]] && mkdir -p "$PGDATA"
    [[ $(stat -c%u ${PGDATA}) != 999 ]] && chown -R postgres "$PGDATA"
    [[ $(stat -c%a ${PGDATA}) != 700 ]] && chmod 700 "$PGDATA"

	# Create the transaction log directory before initdb is run (below) so the directory is owned by the correct user
	if [[ "$POSTGRES_INITDB_XLOGDIR" ]]; then
		mkdir -p "$POSTGRES_INITDB_XLOGDIR"
		chown -R postgres "$POSTGRES_INITDB_XLOGDIR"
		chmod 700 "$POSTGRES_INITDB_XLOGDIR"
	fi

	exec gosu postgres "$BASH_SOURCE" "$@"
fi

if [[ "$1" = 'postgres' ]]; then
    [[ ! -d ${PGDATA} ]] && mkdir -p "$PGDATA"
    [[ $(stat -c%u ${PGDATA}) != $(id -u) ]] && chown -R "$(id -u)" "$PGDATA" 2>/dev/null || :
    [[ $(stat -c%a ${PGDATA}) != 700 ]] && chmod 700 "$PGDATA" 2>/dev/null || :

	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
		# "initdb" is particular about the current user existing in "/etc/passwd", so we use "nss_wrapper" to fake that if necessary
		# see https://github.com/docker-library/postgres/pull/253, https://github.com/docker-library/postgres/issues/359, https://cwrap.org/nss_wrapper.html
		if ! getent passwd "$(id -u)" &> /dev/null && [ -e /usr/lib/libnss_wrapper.so ]; then
			export LD_PRELOAD='/usr/lib/libnss_wrapper.so'
			export NSS_WRAPPER_PASSWD="$(mktemp)"
			export NSS_WRAPPER_GROUP="$(mktemp)"
			echo "postgres:x:$(id -u):$(id -g):PostgreSQL:$PGDATA:/bin/false" > "$NSS_WRAPPER_PASSWD"
			echo "postgres:x:$(id -g):" > "$NSS_WRAPPER_GROUP"
		fi

		file_env 'POSTGRES_USER' 'postgres'
		file_env 'POSTGRES_PASSWORD'

		file_env 'POSTGRES_INITDB_ARGS'
		if [[ "$POSTGRES_INITDB_XLOGDIR" ]]; then
			export POSTGRES_INITDB_ARGS="$POSTGRES_INITDB_ARGS --xlogdir $POSTGRES_INITDB_XLOGDIR"
		fi
		eval 'initdb --username="$POSTGRES_USER" --pwfile=<(echo "$POSTGRES_PASSWORD") '"$POSTGRES_INITDB_ARGS"

		# unset/cleanup "nss_wrapper" bits
		if [[ "${LD_PRELOAD:-}" = '/usr/lib/libnss_wrapper.so' ]]; then
			rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP"
			unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
		fi

		# check password first so we can output the warning before postgres
		# messes it up
		if [ -n "$POSTGRES_PASSWORD" ]; then
			authMethod=md5
		else
			# The - option suppresses leading tabs but *not* spaces. :)
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.

				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			authMethod=trust
		fi

		{
			echo
			echo "host all all all $authMethod"
		} >> "$PGDATA/pg_hba.conf"

		# internal start of server in order to allow set-up using psql-client
		# does not listen on external TCP/IP and waits until start finishes
		PGUSER="${PGUSER:-$POSTGRES_USER}" \
		pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses=''" \
			-w start

		file_env 'POSTGRES_DB' "$POSTGRES_USER"

		export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
		psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password )

		if [[ "$POSTGRES_DB" != 'postgres' ]]; then
			"${psql[@]}" --dbname postgres --set db="$POSTGRES_DB" <<-'EOSQL'
				CREATE DATABASE :"db" ;
			EOSQL
			echo
		fi
		psql+=( --dbname "$POSTGRES_DB" )

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)
					# https://github.com/docker-library/postgres/issues/450#issuecomment-393167936
					# https://github.com/docker-library/postgres/pull/452
					if [[ -x "$f" ]]; then
						echo "$0: running $f"
						"$f"
					else
						echo "$0: sourcing $f"
						. "$f"
					fi
					;;
				*.sql)    echo "$0: running $f"; "${psql[@]}" -f "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

		PGUSER="${PGUSER:-$POSTGRES_USER}" \
		pg_ctl -D "$PGDATA" -m fast -w stop

		unset PGPASSWORD

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	fi
fi

exec "$@"
