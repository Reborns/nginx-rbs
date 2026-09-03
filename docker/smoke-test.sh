#!/usr/bin/env bash
#
# Gate between "image built" and "image pushed".
#
# The .deb pipeline publishes whatever dpkg-buildpackage produced without ever
# starting it. This checks the things that actually go wrong in a from-source
# build: a module that compiled but cannot load because its runtime library is
# missing from the slim image, an OpenSSL that silently fell back to the system
# one, or a version mismatch between what we tagged and what we built.
#
# Usage: smoke-test.sh <image> <expected-nginx-version> <expected-openssl-version>

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image> <nginx-version> <openssl-version>}"
WANT_NGINX="${2:?expected nginx version required}"
WANT_OPENSSL="${3:?expected openssl version required}"

fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
pass() { printf '\033[32m  ok\033[0m  %s\n' "$1"; }
info() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

CONTAINER=""
cleanup() { [ -n "$CONTAINER" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
info "nginx -V"
# ---------------------------------------------------------------------------
VOUT="$(docker run --rm --entrypoint nginx "$IMAGE" -V 2>&1)"
echo "$VOUT"

grep -q "nginx/${WANT_NGINX}\b" <<<"$VOUT" \
  || fail "binary reports a different nginx version than the tag claims (wanted ${WANT_NGINX})"
pass "nginx version is ${WANT_NGINX}"

# This is the check that catches an in-tree OpenSSL build silently not happening.
grep -q "built with OpenSSL ${WANT_OPENSSL}" <<<"$VOUT" \
  || fail "not built against OpenSSL ${WANT_OPENSSL} — check --with-openssl path"
pass "built with OpenSSL ${WANT_OPENSSL}"

# ---------------------------------------------------------------------------
info "configure flags match rules-trixie"
# ---------------------------------------------------------------------------
for flag in \
  --with-http_v3_module \
  --with-http_ssl_module \
  --with-stream_ssl_preread_module \
  --with-mail_ssl_module \
  --with-pcre-jit \
  --with-compat \
  --with-threads \
  --with-file-aio \
  "enable-ktls" \
  "enable-zstd" \
  "enable-brotli" \
  nginx_headers_more_module \
  nginx_dav_ext_module \
  nginx_passenger \
  nginx_module_vts \
  nginx_http_geoip2_module \
  nginx-http-auth-jwt-module \
  nginx_njs
do
  grep -q -- "$flag" <<<"$VOUT" || fail "configure line is missing: $flag"
  pass "$flag"
done

# brotli and zstd are linked via --with-ld-opt, so verify the linkage landed too.
LDD="$(docker run --rm --entrypoint ldd "$IMAGE" /usr/sbin/nginx)"
for lib in libbrotlienc libbrotlidec libzstd; do
  grep -q "$lib" <<<"$LDD" || fail "nginx is not linked against $lib"
  pass "linked: $lib"
done

# ---------------------------------------------------------------------------
info "every module loads (including Passenger)"
# ---------------------------------------------------------------------------
# The real risk in a slim runtime image is a module whose shared library did not
# make it in. Loading all of them at once and running nginx -t proves otherwise.
# Passenger is not enabled by default, so this is where it gets exercised.
ALL_MODULES="$(docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls /etc/nginx/modules-available/*.conf | xargs -n1 basename')"
echo "modules-available: $(tr '\n' ' ' <<<"$ALL_MODULES")"

docker run --rm --entrypoint sh "$IMAGE" -c '
  set -eu
  for f in /etc/nginx/modules-available/*.conf; do
    ln -sf "$f" "/etc/nginx/modules-enabled/$(basename "$f")"
  done
  cp /etc/nginx/conf.d/passenger.conf.example /etc/nginx/conf.d/passenger.conf
  sed -i "s|^# passenger_root|passenger_root|; s|^# passenger_ruby|passenger_ruby|" \
    /etc/nginx/conf.d/passenger.conf
  nginx -t
' || fail "nginx -t failed with all modules loaded — a module is missing a runtime library"
pass "all modules load and nginx -t passes"

# ---------------------------------------------------------------------------
info "Passenger runtime is usable"
# ---------------------------------------------------------------------------
docker run --rm --entrypoint sh "$IMAGE" -c 'passenger-config validate-install --auto' \
  || fail "passenger-config validate-install failed — Ruby or the compiled agent is incomplete"
pass "passenger-config validate-install"

AGENT="$(docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls "$(passenger-config --root)"/buildout/support-binaries/PassengerAgent 2>/dev/null || true')"
[ -n "$AGENT" ] || fail "PassengerAgent binary is absent — compile-agent did not run in the builder"
pass "PassengerAgent present"

# ---------------------------------------------------------------------------
info "container serves traffic"
# ---------------------------------------------------------------------------
CONTAINER="$(docker run -d -P "$IMAGE")"
PORT="$(docker port "$CONTAINER" 80/tcp | head -n1 | sed 's/.*://')"

for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then break; fi
  [ "$i" = 30 ] && fail "container never became healthy on port ${PORT}"
  sleep 1
done
pass "/healthz responded"

curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null || fail "default server did not serve /"
pass "/ served"

# Logs must reach stdout/stderr or nothing is observable in Kubernetes.
docker logs "$CONTAINER" 2>&1 | grep -q "GET /healthz" \
  || fail "access log is not reaching stdout"
pass "access log reaches stdout"

# ---------------------------------------------------------------------------
info "provenance metadata"
# ---------------------------------------------------------------------------
docker run --rm --entrypoint cat "$IMAGE" /usr/share/nginx-rbs/module-commits.txt \
  || fail "module-commits.txt missing from image"
pass "module commit manifest embedded"

printf '\n\033[32mAll smoke tests passed for %s\033[0m\n' "$IMAGE"
