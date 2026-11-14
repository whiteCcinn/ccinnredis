# Redis 2.8 built from the official source tarball. The upstream redis:2.8 image uses a manifest
# format that current containerd releases can no longer unpack.
FROM alpine:3.20 AS build
ARG REDIS_VERSION=2.8.24
RUN apk add --no-cache build-base linux-headers wget \
 && wget -q "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" -O /tmp/redis.tar.gz \
 && mkdir -p /src && tar -xzf /tmp/redis.tar.gz -C /src --strip-components=1 \
 && sed -i 's/^#define HAVE_BACKTRACE 1$//' /src/src/config.h \
 && make -C /src MALLOC=libc CFLAGS="-fcommon -Wno-error" -j4 \
 && cp /src/src/redis-server /src/src/redis-cli /usr/local/bin/

FROM alpine:3.20
COPY --from=build /usr/local/bin/redis-server /usr/local/bin/redis-cli /usr/local/bin/
EXPOSE 6379
CMD ["redis-server", "--port", "6379", "--bind", "0.0.0.0"]
