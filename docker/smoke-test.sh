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
  ngx_brotli \
  nginx_passenger \
  nginx_module_vts \
  nginx_http_geoip2_module \
  nginx-http-auth-jwt-module \
  nginx_njs \
  ngx_devel_kit \
  lua-nginx-module
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

# --user root here on purpose: /etc/nginx is deliberately NOT writable by the
# nginx user, and this step rewrites config to force-load every module. It is
# testing that the modules link, not that the runtime user can edit config.
docker run --rm --user root --entrypoint sh "$IMAGE" -c '
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
# Also --user root: validate-install may compile native support into the gem
# dir, which the nginx user cannot write. This validates the install itself.
docker run --rm --user root --entrypoint sh "$IMAGE" -c 'passenger-config validate-install --auto' \
  || fail "passenger-config validate-install failed — Ruby or the compiled agent is incomplete"
pass "passenger-config validate-install"

AGENT="$(docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls "$(passenger-config --root)"/buildout/support-binaries/PassengerAgent 2>/dev/null || true')"
[ -n "$AGENT" ] || fail "PassengerAgent binary is absent — compile-agent did not run in the builder"
pass "PassengerAgent present"

# ---------------------------------------------------------------------------
info "runs unprivileged"
# ---------------------------------------------------------------------------
UID_OUT="$(docker run --rm --entrypoint id "$IMAGE" -u)"
[ "$UID_OUT" != "0" ] || fail "image runs as root; USER nginx is not in effect"
pass "default user is uid ${UID_OUT} (non-root)"

# A config the runtime user can rewrite is a config a compromised worker can
# rewrite. Assert it stays read-only to that user.
docker run --rm --entrypoint sh "$IMAGE" -c 'touch /etc/nginx/_writetest 2>/dev/null' \
  && fail "/etc/nginx is writable by the runtime user; it should be root-owned and read-only" \
  || pass "/etc/nginx is not writable by the runtime user"

# ---------------------------------------------------------------------------
info "troubleshooting tools present"
# ---------------------------------------------------------------------------
for tool in curl wget dig host netstat; do
  docker run --rm --entrypoint sh "$IMAGE" -c "command -v $tool >/dev/null" \
    || fail "$tool is missing from the image"
  pass "$tool"
done

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

# ngx_brotli is compiled in but off unless configured; nginx -t proves the
# directives are known to the binary.
docker run --rm --user root --entrypoint sh "$IMAGE" -c '
  printf "brotli on;\nbrotli_static on;\nbrotli_types text/plain;\n" > /etc/nginx/conf.d/zz-brotli-test.conf
  nginx -t
' || fail "brotli directives rejected — ngx_brotli is not compiled in"
pass "brotli / brotli_static directives accepted"

# Lua is checked by serving a request, not by nginx -t: with the bundled
# lua-resty-core missing or mismatched, nginx -t still passes but nginx itself
# refuses to start. ngx.re and ngx.shared exercise resty.core; set_by_lua
# exercises ngx_devel_kit; lrucache exercises the second bundled library.
LUA_OUT="$(docker run --rm --user root --entrypoint sh "$IMAGE" -c '
  cat > /etc/nginx/conf.d/zz-lua-test.conf <<EOF
lua_shared_dict rbs_test 1m;
server {
  listen 8099;
  location = /lua {
    set_by_lua_block \$answer { return tostring(6 * 7) }
    content_by_lua_block {
      local lru = require("resty.lrucache").new(1)
      lru:set("k", "lru")
      ngx.shared.rbs_test:set("k", "shm")
      local m = ngx.re.match("v1.2", [[(\d+)\.(\d+)]], "jo")
      ngx.say(package.loaded["resty.core"] and "core" or "nocore", " ",
              m[2], " ", ngx.var.answer, " ", ngx.shared.rbs_test:get("k"), " ", (lru:get("k")))
    }
  }
}
EOF
  nginx 2>/tmp/nginx.err || { cat /tmp/nginx.err; exit 1; }
  sleep 1
  curl -fsS http://127.0.0.1:8099/lua
' 2>&1)" || fail "Lua test request failed: ${LUA_OUT}"
[ "$LUA_OUT" = "core 2 42 shm lru" ] || fail "unexpected Lua output: '${LUA_OUT}'"
pass "lua: resty.core, ngx.re, shared dict, lrucache and set_by_lua (NDK) all work"

# Logs must reach stdout/stderr or nothing is observable in Kubernetes.
#
# Assert on `GET /`, NOT on `/healthz`: default.conf deliberately sets
# `access_log off` for the health endpoint so probes do not flood the log, so a
# /healthz request is never written anywhere and can never be matched here.
#
# Check the symlinks separately from the log content, so a failure says which
# half broke, and dump what the container actually emitted rather than
# swallowing it in `grep -q`.
for pair in "access.log:/dev/stdout" "error.log:/dev/stderr"; do
  logfile="${pair%%:*}"; want="${pair##*:}"
  got="$(docker run --rm --entrypoint readlink "$IMAGE" "/var/log/nginx/${logfile}" 2>/dev/null || true)"
  [ "$got" = "$want" ] || fail "/var/log/nginx/${logfile} should link to ${want}, got '${got:-<nothing>}'"
  pass "${logfile} -> ${want}"
done

LOGS="$(docker logs "$CONTAINER" 2>&1)"
if ! grep -q 'GET / HTTP' <<<"$LOGS"; then
  echo "--- container stdout/stderr follows ---" >&2
  printf '%s\n' "$LOGS" | tail -n 30 >&2
  echo "--- end container output ---" >&2
  fail "access log is not reaching stdout"
fi
pass "access log reaches stdout"

# ---------------------------------------------------------------------------
info "provenance metadata"
# ---------------------------------------------------------------------------
docker run --rm --entrypoint cat "$IMAGE" /usr/share/nginx-rbs/module-commits.txt \
  || fail "module-commits.txt missing from image"
pass "module commit manifest embedded"

printf '\n\033[32mAll smoke tests passed for %s\033[0m\n' "$IMAGE"
