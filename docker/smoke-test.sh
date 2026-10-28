#!/usr/bin/env bash
#
# Checks the image before it is pushed.
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

# Fails if the in-tree OpenSSL was not used.
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

# brotli and zstd come from --with-ld-opt.
LDD="$(docker run --rm --entrypoint ldd "$IMAGE" /usr/sbin/nginx)"
for lib in libbrotlienc libbrotlidec libzstd; do
  grep -q "$lib" <<<"$LDD" || fail "nginx is not linked against $lib"
  pass "linked: $lib"
done

# ---------------------------------------------------------------------------
info "every module loads (including Passenger)"
# ---------------------------------------------------------------------------
# Load every module, Passenger included, and run nginx -t.
ALL_MODULES="$(docker run --rm --entrypoint sh "$IMAGE" -c \
  'ls /etc/nginx/modules-available/*.conf | xargs -n1 basename')"
echo "modules-available: $(tr '\n' ' ' <<<"$ALL_MODULES")"

# root: /etc/nginx is read-only for the nginx user.
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
# root: validate-install may write into the gem dir.
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

# /etc/nginx must stay read-only for the nginx user.
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

# brotli is enabled in nginx.conf.
HDRS="$(curl -fsS -o /dev/null -D - -H "Accept-Encoding: br" "http://127.0.0.1:${PORT}/")"
grep -qi '^content-encoding: br' <<<"$HDRS" || fail "/ was not served brotli-compressed"
pass "brotli compression"

# A real request: nginx -t passes even when resty.core is missing.
LUA_OUT="$(docker run --rm --user root --entrypoint sh "$IMAGE" -c '
  cat > /etc/nginx/conf.d/zz-lua-test.conf <<EOF
lua_shared_dict rbs_test 1m;
server {
  listen 8099;
  access_log off;
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
  # nginx logs to stdout/stderr; keep that out of the compared output.
  nginx >/tmp/nginx.out 2>&1 || { cat /tmp/nginx.out; exit 1; }
  sleep 1
  curl -fsS http://127.0.0.1:8099/lua
' 2>&1)" || fail "Lua test request failed: ${LUA_OUT}"
[ "$LUA_OUT" = "core 2 42 shm lru" ] || fail "unexpected Lua output: '${LUA_OUT}'"
pass "lua: resty.core, ngx.re, shared dict, lrucache and set_by_lua (NDK) all work"

# Logs must reach stdout/stderr. /healthz has access_log off, so check GET /.
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
