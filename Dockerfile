# renovate: datasource=docker packageName=library/postgres
ARG POSTGRES_VERSION=18.3-trixie
FROM docker.io/library/postgres:${POSTGRES_VERSION} AS builder

# renovate: datasource=github-tags packageName=documentdb/documentdb
ARG DOCUMENTDB_VERSION=v0.111-0
# renovate: datasource=github-tags packageName=pgvector/pgvector
ARG PGVECTOR_VERSION=v0.8.2

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		build-essential \
		ca-certificates \
		cmake \
		curl \
		git \
		libicu-dev \
		libkrb5-dev \
		libssl-dev \
		pkg-config \
		postgresql-server-dev-18 \
		zlib1g-dev \
	; \
	rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN set -eux; \
	git clone --depth 1 --branch "${DOCUMENTDB_VERSION}" https://github.com/documentdb/documentdb.git documentdb; \
	git clone --depth 1 --branch "${PGVECTOR_VERSION}" https://github.com/pgvector/pgvector.git pgvector

WORKDIR /build/documentdb

ENV INSTALL_DEPENDENCIES_ROOT=/tmp/documentdb-build-deps
ENV CLEANUP_SETUP=1

RUN set -eux; \
	mkdir -p "${INSTALL_DEPENDENCIES_ROOT}"; \
	MAKE_PROGRAM=cmake ./scripts/install_setup_libbson.sh; \
	./scripts/install_setup_pcre2.sh; \
	./scripts/install_setup_intel_decimal_math_lib.sh; \
	rm -rf "${INSTALL_DEPENDENCIES_ROOT}"

WORKDIR /build/pgvector

RUN set -eux; \
	make clean; \
	make -j"$(nproc)" OPTFLAGS=""; \
	make install

WORKDIR /build/documentdb

RUN set -eux; \
	make -C pg_documentdb_core -j"$(nproc)"; \
	make -C pg_documentdb_core install; \
	make -C pg_documentdb -j"$(nproc)"; \
	make -C pg_documentdb install; \
	make -C pg_documentdb_extended_rum -j"$(nproc)"; \
	make -C pg_documentdb_extended_rum install

FROM docker.io/library/postgres:${POSTGRES_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		postgresql-18-cron \
		postgresql-18-postgis-3 \
	; \
	rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/lib/postgresql/18/lib/vector.so /usr/lib/postgresql/18/lib/
COPY --from=builder /usr/lib/postgresql/18/lib/pg_documentdb*.so /usr/lib/postgresql/18/lib/
COPY --from=builder /usr/share/postgresql/18/extension/vector* /usr/share/postgresql/18/extension/
COPY --from=builder /usr/share/postgresql/18/extension/documentdb* /usr/share/postgresql/18/extension/
COPY --chown=postgres:postgres docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

RUN set -eux; \
	{ \
		echo; \
		echo "# DocumentDB shared libraries"; \
		echo "shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum'"; \
		echo "cron.database_name = 'postgres'"; \
		echo "documentdb.rum_library_load_option = 'require_documentdb_extended_rum'"; \
		echo "documentdb.alternate_index_handler_name = 'extended_rum'"; \
	} >> /usr/share/postgresql/postgresql.conf.sample
