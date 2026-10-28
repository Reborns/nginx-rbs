# syntax=docker/dockerfile:1.9
#
# nginx mainline from source, with the same configure flags, hardening and
# modules as rules-trixie. Versions and SHA256 digests come from the workflow.

ARG DEBIAN_SUITE=trixie

# ---------------------------------------------------------------------------
# Stage 1 — builder
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_SUITE} AS builder

ARG NGINX_VERSION
ARG NGINX_SHA256
ARG OPENSSL_VERSION
ARG OPENSSL_SHA256
# Empty = latest Passenger gem.
ARG PASSENGER_VERSION=""

# Module refs: empty = default branch HEAD, or a tag/commit SHA.
ARG NJS_REF=""
ARG HEADERS_MORE_REF=""
ARG DAV_EXT_REF=""
ARG VTS_REF=""
ARG GEOIP2_REF=""
ARG AUTH_JWT_REF=""
ARG BROTLI_REF=""
# Lua stack is pinned: lua-resty-core must match lua-nginx-module.
# Keep in sync with the .deb workflows.
ARG LUA_NGINX_MODULE_REF="v0.10.31"
ARG LUA_RESTY_CORE_REF="v0.1.34rc3"
ARG LUA_RESTY_LRUCACHE_REF="v0.15"
ARG NDK_REF="v0.3.4"
ARG LUAJIT_REF="v2.1-20260917"

ENV MODULES_DIR=/opt/nginx-modules \
    DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Fail early on missing build args.
RUN for v in NGINX_VERSION NGINX_SHA256 OPENSSL_VERSION OPENSSL_SHA256; do \
      if [ -z "${!v:-}" ]; then echo "FATAL: build-arg $v is required and empty" >&2; exit 1; fi; \
    done; \
    echo "Building nginx ${NGINX_VERSION} against OpenSSL ${OPENSSL_VERSION}"

# --- build dependencies -----------------------------------------------------
# libxslt1-dev: required by dav-ext and njs, even without the XSLT module.
# file: used by Passenger's libev/libuv configure scripts.
RUN apt-get -qq update \
 && apt-get -qq install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      dpkg-dev \
      file \
      git \
      libbrotli-dev \
      libcurl4-openssl-dev \
      libjansson-dev \
      libjwt-dev \
      libmaxminddb-dev \
      libpcre2-dev \
      libssl-dev \
      libxslt1-dev \
      libzstd-dev \
      pkg-config \
      rake \
      ruby \
      ruby-dev \
      wget \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# --- nginx + OpenSSL sources, checked against the digests ------------------
RUN mkdir -p "$MODULES_DIR" /usr/src \
 && curl -fSL --retry 3 --retry-delay 2 \
      "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
      -o /usr/src/nginx.tar.gz \
 && echo "${NGINX_SHA256}  /usr/src/nginx.tar.gz" | sha256sum -c - \
 && tar -xzf /usr/src/nginx.tar.gz -C /usr/src \
 && curl -fSL --retry 3 --retry-delay 2 \
      "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
      -o /usr/src/openssl.tar.gz \
 && echo "${OPENSSL_SHA256}  /usr/src/openssl.tar.gz" | sha256sum -c - \
 && tar -xzf /usr/src/openssl.tar.gz -C "$MODULES_DIR" \
 && test -d "$MODULES_DIR/openssl-${OPENSSL_VERSION}" \
 && rm -f /usr/src/nginx.tar.gz /usr/src/openssl.tar.gz

# --- third-party modules ----------------------------------------------------
# clone <url> <ref> <dest>: ref = empty, tag/branch, or commit SHA.
RUN set -euo pipefail; \
    clone() { \
      local url="$1" ref="$2" dest="$3"; \
      if [ -z "$ref" ]; then \
        git clone -q --single-branch --depth 1 "$url" "$dest"; \
      elif git clone -q --single-branch --depth 1 --branch "$ref" "$url" "$dest" 2>/dev/null; then \
        :; \
      else \
        git clone -q "$url" "$dest" && git -C "$dest" checkout -q "$ref"; \
      fi; \
    }; \
    clone https://github.com/nginx/njs.git                          "$NJS_REF"           "$MODULES_DIR/nginx_njs"; \
    clone https://github.com/openresty/headers-more-nginx-module.git "$HEADERS_MORE_REF" "$MODULES_DIR/nginx_headers_more_module"; \
    clone https://github.com/arut/nginx-dav-ext-module.git          "$DAV_EXT_REF"       "$MODULES_DIR/nginx_dav_ext_module"; \
    clone https://github.com/vozlt/nginx-module-vts.git             "$VTS_REF"           "$MODULES_DIR/nginx_module_vts"; \
    clone https://github.com/leev/ngx_http_geoip2_module.git        "$GEOIP2_REF"        "$MODULES_DIR/nginx_http_geoip2_module"; \
    clone https://github.com/TeslaGov/ngx-http-auth-jwt-module.git  "$AUTH_JWT_REF"      "$MODULES_DIR/nginx-http-auth-jwt-module"; \
    clone https://github.com/google/ngx_brotli.git                  "$BROTLI_REF"        "$MODULES_DIR/ngx_brotli"; \
    # ngx_brotli: use libbrotli-dev headers instead of its git submodule.
    mkdir -p "$MODULES_DIR/ngx_brotli/deps/brotli/c/include"; \
    ln -sfn /usr/include/brotli "$MODULES_DIR/ngx_brotli/deps/brotli/c/include/brotli"; \
    clone https://github.com/openresty/lua-nginx-module.git        "$LUA_NGINX_MODULE_REF"   "$MODULES_DIR/lua-nginx-module"; \
    clone https://github.com/openresty/lua-resty-core.git          "$LUA_RESTY_CORE_REF"     "$MODULES_DIR/lua-resty-core"; \
    clone https://github.com/openresty/lua-resty-lrucache.git      "$LUA_RESTY_LRUCACHE_REF" "$MODULES_DIR/lua-resty-lrucache"; \
    clone https://github.com/vision5/ngx_devel_kit.git             "$NDK_REF"                "$MODULES_DIR/ngx_devel_kit"; \
    clone https://github.com/openresty/luajit2.git                 "$LUAJIT_REF"             "$MODULES_DIR/luajit2"

# --- LuaJIT + Lua libraries -------------------------------------------------
# Static OpenResty LuaJIT (-fPIC), bundled lua-resty-* path compiled into the
# module, and a check that lua-resty-core matches lua-nginx-module.
RUN set -euo pipefail; \
    make -C "$MODULES_DIR/luajit2" -j"$(nproc)" CFLAGS=-fPIC PREFIX=/usr > /dev/null; \
    make -C "$MODULES_DIR/luajit2" install PREFIX=/usr DESTDIR=/opt/luajit > /dev/null; \
    rm -f /opt/luajit/usr/lib/libluajit-5.1.so*; \
    sed -i '1i #ifndef LUA_DEFAULT_PATH\n#define LUA_DEFAULT_PATH "/usr/share/nginx-rbs/lua/?.lua;/usr/share/nginx-rbs/lua/?/init.lua"\n#endif' \
      "$MODULES_DIR/lua-nginx-module/src/ngx_http_lua_util.c"; \
    make -C "$MODULES_DIR/lua-resty-core" install LUA_LIB_DIR=/opt/nginx-lua > /dev/null; \
    make -C "$MODULES_DIR/lua-resty-lrucache" install LUA_LIB_DIR=/opt/nginx-lua > /dev/null; \
    HAVE="$(grep -oE 'ngx_http_lua_version +[0-9]+' "$MODULES_DIR/lua-nginx-module/src/api/ngx_http_lua_api.h" | awk '{print $2}')"; \
    WANT="$(grep -oE 'ngx_lua_version ~= [0-9]+' /opt/nginx-lua/resty/core/base.lua | head -n 1 | awk '{print $3}')"; \
    if [ -z "$HAVE" ] || [ "$HAVE" != "$WANT" ]; then \
      echo "FATAL: lua-resty-core $LUA_RESTY_CORE_REF needs ngx_lua $WANT, lua-nginx-module $LUA_NGINX_MODULE_REF is $HAVE" >&2; exit 1; \
    fi; \
    echo "lua-nginx-module $LUA_NGINX_MODULE_REF ($HAVE) + lua-resty-core $LUA_RESTY_CORE_REF: matched"

# Record the commit of each module.
RUN set -euo pipefail; \
    : > /opt/module-commits.txt; \
    for d in "$MODULES_DIR"/*/; do \
      if [ -d "$d/.git" ]; then \
        printf '%s=%s\n' "$(basename "$d")" "$(git -C "$d" rev-parse HEAD)" >> /opt/module-commits.txt; \
      fi; \
    done; \
    printf 'openssl=%s\n' "${OPENSSL_VERSION}" >> /opt/module-commits.txt; \
    cat /opt/module-commits.txt

# --- Passenger dynamic module ----------------------------------------------
# Passenger addon, built as a dynamic module.
RUN set -euo pipefail; \
    if [ -n "$PASSENGER_VERSION" ]; then \
      gem install passenger -v "$PASSENGER_VERSION" --no-document; \
    else \
      gem install passenger --no-document; \
    fi; \
    passenger-config --version > /opt/passenger-version; \
    passenger-config --root    > /opt/passenger-root; \
    ADDON_DIR="$(passenger-config --nginx-addon-dir)"; \
    cd "$ADDON_DIR" && rake -sq nginx:as_dynamic_module CACHING=false; \
    ln -sfn "$ADDON_DIR" "$MODULES_DIR/nginx_passenger"; \
    echo "passenger=$(cat /opt/passenger-version)" >> /opt/module-commits.txt

# Compile the Passenger agent here; the runtime image has no compiler.
RUN passenger-config compile-agent --auto --optimize

# --- configure + build ------------------------------------------------------
# dpkg-buildflags with rules-trixie's DEB_*_MAINT_APPEND values; configure
# flags as in rules-trixie, without its duplicates.
RUN set -euo pipefail; \
    cd "/usr/src/nginx-${NGINX_VERSION}"; \
    export DEB_BUILD_MAINT_OPTIONS=hardening=+all; \
    export DEB_CFLAGS_MAINT_APPEND="-Wp,-D_FORTIFY_SOURCE=2 -fPIC -DNGX_LINKED_LIST_COOKIES=1"; \
    export DEB_LDFLAGS_MAINT_APPEND="-Wl,--as-needed -pie"; \
    BUILD_CFLAGS="$(dpkg-buildflags --get CFLAGS) $(dpkg-buildflags --get CPPFLAGS)"; \
    BUILD_LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"; \
    echo "CFLAGS: $BUILD_CFLAGS"; \
    echo "LDFLAGS: $BUILD_LDFLAGS"; \
    LUAJIT_LIB=/opt/luajit/usr/lib LUAJIT_INC=/opt/luajit/usr/include/luajit-2.1 \
    CFLAGS="" ./configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --modules-path=/usr/lib/nginx/modules \
      --conf-path=/etc/nginx/nginx.conf \
      --error-log-path=/var/log/nginx/error.log \
      --http-log-path=/var/log/nginx/access.log \
      --pid-path=/var/run/nginx.pid \
      --lock-path=/var/run/nginx.lock \
      --http-client-body-temp-path=/var/cache/nginx/client_temp \
      --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
      --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
      --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
      --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
      --user=nginx \
      --group=nginx \
      --with-compat \
      --with-file-aio \
      --with-threads \
      --with-pcre-jit \
      --with-http_addition_module \
      --with-http_auth_request_module \
      --with-http_dav_module \
      --with-http_flv_module \
      --with-http_gunzip_module \
      --with-http_gzip_static_module \
      --with-http_mp4_module \
      --with-http_random_index_module \
      --with-http_realip_module \
      --with-http_secure_link_module \
      --with-http_slice_module \
      --with-http_ssl_module \
      --with-http_stub_status_module \
      --with-http_sub_module \
      --with-http_v2_module \
      --with-http_v3_module \
      --with-mail \
      --with-mail_ssl_module \
      --with-stream \
      --with-stream_realip_module \
      --with-stream_ssl_module \
      --with-stream_ssl_preread_module \
      --with-openssl="${MODULES_DIR}/openssl-${OPENSSL_VERSION}" \
      --with-openssl-opt='enable-ktls threads enable-zlib enable-zstd enable-brotli -fPIC' \
      --add-module="${MODULES_DIR}/nginx_headers_more_module" \
      --add-module="${MODULES_DIR}/nginx_dav_ext_module" \
      --add-module="${MODULES_DIR}/ngx_brotli" \
      --add-dynamic-module="${MODULES_DIR}/nginx_passenger" \
      --add-dynamic-module="${MODULES_DIR}/nginx_module_vts" \
      --add-dynamic-module="${MODULES_DIR}/nginx_http_geoip2_module" \
      --add-dynamic-module="${MODULES_DIR}/nginx-http-auth-jwt-module" \
      --add-dynamic-module="${MODULES_DIR}/nginx_njs/nginx" \
      --add-dynamic-module="${MODULES_DIR}/ngx_devel_kit" \
      --add-dynamic-module="${MODULES_DIR}/lua-nginx-module" \
      --with-cc-opt="$BUILD_CFLAGS" \
      --with-ld-opt="$BUILD_LDFLAGS -Wl,--no-as-needed -lbrotlienc -lbrotlidec -lbrotlicommon -lzstd -Wl,--as-needed" \
 && make -j"$(nproc)" \
 && make install

# Strip, as dh_strip does.
RUN strip /usr/sbin/nginx \
 && find /usr/lib/nginx/modules -name '*.so' -exec strip {} +

# --- resolve runtime library packages --------------------------------------
# Packages providing the libraries nginx and its modules link against.
RUN set -euo pipefail; \
    { ldd /usr/sbin/nginx; for m in /usr/lib/nginx/modules/*.so; do ldd "$m"; done; } \
      | awk '/=> \//{print $3}' | sort -u \
      | xargs -r realpath -e 2>/dev/null | sort -u \
      | xargs -r dpkg -S 2>/dev/null \
      | cut -d: -f1 | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u \
      > /opt/runtime-deps.txt; \
    if [ ! -s /opt/runtime-deps.txt ]; then echo "FATAL: runtime dep detection produced nothing" >&2; exit 1; fi; \
    echo "--- resolved runtime packages ---"; cat /opt/runtime-deps.txt

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_SUITE}-slim AS runtime

ARG NGINX_VERSION
ARG OPENSSL_VERSION
ARG DEBIAN_SUITE
ARG BUILD_DATE=""
ARG VCS_REF=""

ENV DEBIAN_FRONTEND=noninteractive \
    NGINX_VERSION=${NGINX_VERSION} \
    OPENSSL_VERSION=${OPENSSL_VERSION}

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

COPY --from=builder /opt/runtime-deps.txt /tmp/runtime-deps.txt

# ruby: needed by Passenger. curl, wget, dig, host, netstat: debugging tools.
RUN apt-get -qq update \
 && apt-get -qq install -y --no-install-recommends \
      bind9-dnsutils \
      bind9-host \
      ca-certificates \
      curl \
      net-tools \
      iputils-ping \
      ruby \
      tzdata \
      wget \
      $(tr '\n' ' ' < /tmp/runtime-deps.txt) \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-deps.txt

# nginx itself, its modules, and the compiled Passenger runtime.
COPY --from=builder /usr/sbin/nginx           /usr/sbin/nginx
COPY --from=builder /usr/lib/nginx/modules    /usr/lib/nginx/modules
COPY --from=builder /etc/nginx                /etc/nginx
COPY --from=builder /var/lib/gems             /var/lib/gems
COPY --from=builder /usr/local/bin/passenger* /usr/local/bin/
COPY --from=builder /opt/module-commits.txt   /usr/share/nginx-rbs/module-commits.txt
COPY --from=builder /opt/passenger-root       /usr/share/nginx-rbs/passenger-root
COPY --from=builder /opt/passenger-version    /usr/share/nginx-rbs/passenger-version
COPY --from=builder /opt/nginx-lua            /usr/share/nginx-rbs/lua

# nginx user, cache/log dirs, docroot moved to /usr/share/nginx/html.
RUN set -euo pipefail; \
    groupadd --system --gid 101 nginx; \
    useradd --system --gid nginx --no-create-home --home /nonexistent \
            --shell /usr/sbin/nologin --uid 101 nginx; \
    mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp \
             /var/log/nginx \
             /etc/nginx/conf.d \
             /etc/nginx/sites-available \
             /etc/nginx/sites-enabled \
             /etc/nginx/modules-available \
             /etc/nginx/modules-enabled; \
    chown -R nginx:nginx /var/cache/nginx; \
    ln -sfn /usr/lib/nginx/modules /etc/nginx/modules; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    mkdir -p /usr/share/nginx; \
    if [ -d /etc/nginx/html ]; then mv /etc/nginx/html /usr/share/nginx/html; \
    else mkdir -p /usr/share/nginx/html; fi; \
    ln -sfn /usr/share/nginx/html /etc/nginx/html; \
    test -f /usr/share/nginx/html/index.html

# One load_module snippet per module; all enabled except Passenger.
RUN set -euo pipefail; \
    gen() { printf 'load_module modules/%s;\n' "$2" > "/etc/nginx/modules-available/$1.conf"; }; \
    gen 10-http-js           ngx_http_js_module.so; \
    gen 11-stream-js         ngx_stream_js_module.so; \
    gen 20-http-vts          ngx_http_vhost_traffic_status_module.so; \
    gen 30-http-geoip2       ngx_http_geoip2_module.so; \
    gen 31-stream-geoip2     ngx_stream_geoip2_module.so; \
    gen 40-http-auth-jwt     ngx_http_auth_jwt_module.so; \
    gen 50-http-passenger    ngx_http_passenger_module.so; \
    gen 60-http-ndk          ndk_http_module.so; \
    gen 61-http-lua          ngx_http_lua_module.so; \
    for f in /etc/nginx/modules-available/*.conf; do \
      case "$f" in *passenger*) continue ;; esac; \
      ln -sf "$f" "/etc/nginx/modules-enabled/$(basename "$f")"; \
    done; \
    ls -l /etc/nginx/modules-enabled/

COPY nginx.conf     /etc/nginx/nginx.conf
COPY default.conf   /etc/nginx/conf.d/default.conf
COPY passenger.conf /etc/nginx/conf.d/passenger.conf.example

# Fill in the real Passenger paths.
RUN set -euo pipefail; \
    PR="$(cat /usr/share/nginx-rbs/passenger-root)"; \
    RUBY="$(command -v ruby)"; \
    sed -i "s|@PASSENGER_ROOT@|${PR}|g; s|@PASSENGER_RUBY@|${RUBY}|g" \
      /etc/nginx/conf.d/passenger.conf.example; \
    nginx -t

LABEL org.opencontainers.image.title="nginx-rbs" \
      org.opencontainers.image.description="nginx mainline with in-tree OpenSSL (ktls/zlib/zstd/brotli), njs, Lua, VTS, GeoIP2, auth-JWT, headers-more, dav-ext, brotli and Passenger — matching the RBS Debian packages" \
      org.opencontainers.image.source="https://github.com/Reborns/nginx-rbs" \
      org.opencontainers.image.version="${NGINX_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="BSD-2-Clause" \
      io.rbs.nginx.version="${NGINX_VERSION}" \
      io.rbs.openssl.version="${OPENSSL_VERSION}" \
      io.rbs.debian.suite="${DEBIAN_SUITE}"

# --- drop privileges -------------------------------------------------------
# Runs as nginx; only cache, logs and the pid file are writable.
# /etc/nginx stays root-owned and read-only.
RUN set -euo pipefail; \
    touch /var/run/nginx.pid; \
    chown nginx:nginx /var/run/nginx.pid; \
    chown -R nginx:nginx /var/cache/nginx; \
    chown nginx:nginx /var/log/nginx; \
    chmod -R a+rX /etc/nginx; \
    chmod 755 /usr/share/nginx/html

# 443/udp for HTTP/3.
EXPOSE 80 443 443/udp

STOPSIGNAL SIGQUIT

WORKDIR /etc/nginx

USER nginx

CMD ["nginx", "-g", "daemon off;"]
