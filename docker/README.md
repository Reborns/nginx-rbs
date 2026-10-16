# nginx-rbs container image

`reborns/nginx-rbs` — nginx mainline compiled from source with the same OpenSSL
treatment, hardening flags and module set as the RBS Debian packages.

This is an **independent** build path. It does not consume a `.deb`, OpenRepo, or
the download host. Parity with `rules-trixie` is maintained by:

- reusing the same `./configure` argument list (with the three duplicated flags
  collapsed — `--with-compat`, `--with-file-aio`, `--with-threads` each appear
  twice in `rules-trixie`)
- deriving `CFLAGS`/`LDFLAGS` from `dpkg-buildflags` with the identical
  `DEB_BUILD_MAINT_OPTIONS=hardening=+all`,
  `DEB_CFLAGS_MAINT_APPEND` and `DEB_LDFLAGS_MAINT_APPEND` values, so compiler
  and linker hardening match the package rather than merely resembling it
- building OpenSSL in-tree with the same
  `enable-ktls threads enable-zlib enable-zstd enable-brotli -fPIC`

## What's in it

| | |
|---|---|
| OpenSSL | latest 3.x, in-tree, ktls + zlib + zstd + brotli |
| Static modules | `headers-more`, `dav-ext`, `brotli` (filter + static) |
| Dynamic modules | `njs` (http + stream), `VTS`, `GeoIP2` (http + stream), `auth-JWT`, `Passenger` |
| HTTP/3 | yes — `--with-http_v3_module`; `443/udp` is exposed |
| Base | `debian:trixie-slim` |
| Platform | `linux/amd64` |
| Runs as | `nginx` (uid 101), non-root |
| Tools | `curl`, `wget`, `dig`, `nslookup`, `host`, `ifconfig`, `netstat` |

Note the tradeoff on that last row: `curl`, `wget` and DNS/network tooling are
useful for debugging inside a running pod and are also the standard
post-exploitation toolkit. They are here because they were asked for; if you
later want them out of the production image, build a second stage that adds them
and publish it as a `-debug` tag instead.

## Tags

Two tags, both pointing at the same digest:

| Tag | Meaning |
|---|---|
| `1.31.5-trixie` | that nginx version |
| `latest` | always the newest build |

Pin the version tag in production. `latest` is unambiguous only because trixie
is the sole suite this workflow builds — adding bookworm or bullseye here would
make it mean "whichever suite ran last", so revisit it first.

The tag list is a single array in the workflow's "Tag and push" step; change it
there.

**The nginx version is the only build trigger.** The workflow checks whether
`<nginx>-trixie` already exists on the registry; if it does, nothing is built.
Each build compiles against whatever OpenSSL 3.x is current at that moment, and
the version that went in is recorded in the image's `io.rbs.openssl.version`
label and in `module-commits.txt`.

The consequence worth knowing: an OpenSSL security release with no accompanying
nginx release will not produce a rebuild on its own. To pick up a new OpenSSL
against an unchanged nginx, dispatch the workflow with `force_build: true` —
that re-pushes both tags to the new digest.

## Running unprivileged

The image runs as the `nginx` user (uid 101), master process included, and still
listens on 80/443 — container runtimes set
`net.ipv4.ip_unprivileged_port_start=0`, so no `setcap` and no port change are
needed. The exception is OpenShift, or any runtime pinning that sysctl to 1024:
there, either set the sysctl or switch the `listen` directives to 8080/8443.

Only the paths nginx writes are owned by it — `/var/cache/nginx`,
`/var/log/nginx`, `/var/run/nginx.pid`. **`/etc/nginx` stays root-owned and
read-only to the nginx user**, because nginx only ever reads its config and a
writable config is one a compromised worker can rewrite and reload. If you add
startup-time config templating you will need to widen that; nothing in this
image does.

The smoke test asserts both properties, so a regression fails the build rather
than shipping quietly.

## Dynamic modules

Loaded via snippets in `/etc/nginx/modules-available/`, enabled by symlink into
`/etc/nginx/modules-enabled/`. Everything is enabled by default **except
Passenger**, because loading the Passenger module starts its watchdog and agent
processes in every container whether or not you serve a Ruby app.

To turn Passenger on:

```dockerfile
FROM reborns/nginx-rbs:latest
RUN ln -sf /etc/nginx/modules-available/50-http-passenger.conf \
           /etc/nginx/modules-enabled/50-http-passenger.conf
COPY passenger.conf /etc/nginx/conf.d/passenger.conf
```

`/etc/nginx/conf.d/passenger.conf.example` in the image already has the correct
`passenger_root` and `passenger_ruby` substituted in. Note that the symlink and
the COPY both need root, so put them in a build stage rather than trying them at
runtime.

To turn a module off, remove its symlink. `default.conf` is intentionally free of
module-specific directives so that removing one never breaks startup.

## Provenance

Every image carries `/usr/share/nginx-rbs/module-commits.txt` — the exact commit
SHA of each third-party module and the OpenSSL and Passenger versions that went
in. Module refs default to floating HEAD, matching the `.deb` pipeline's
behaviour, so this manifest is how you find out afterwards what a given image
actually contains:

```sh
docker run --rm reborns/nginx-rbs:latest \
  cat /usr/share/nginx-rbs/module-commits.txt
```

To pin instead, set any of the `*_REF` build args (`NJS_REF`,
`HEADERS_MORE_REF`, `DAV_EXT_REF`, `VTS_REF`, `GEOIP2_REF`, `AUTH_JWT_REF`,
`BROTLI_REF`, `PASSENGER_VERSION`) to a tag or commit SHA.

## Building locally

Both version arguments and both digests are required; the build fails fast
rather than producing a subtly wrong image.

```sh
NGINX_VERSION=1.31.5
OPENSSL_VERSION=3.6.4

curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
curl -fsSLO "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

docker build ./docker \
  --build-arg "NGINX_VERSION=${NGINX_VERSION}" \
  --build-arg "NGINX_SHA256=$(sha256sum nginx-${NGINX_VERSION}.tar.gz | cut -d' ' -f1)" \
  --build-arg "OPENSSL_VERSION=${OPENSSL_VERSION}" \
  --build-arg "OPENSSL_SHA256=$(sha256sum openssl-${OPENSSL_VERSION}.tar.gz | cut -d' ' -f1)" \
  -t nginx-rbs:candidate

./docker/smoke-test.sh nginx-rbs:candidate "${NGINX_VERSION}" "${OPENSSL_VERSION}"
```

## Required secrets

| Secret | Used for |
|---|---|
| `DOCKERHUB_USERNAME` | registry login |
| `DOCKERHUB_TOKEN` | registry login — use an access token with Read & Write, not the account password |
| `MAIL_USERNAME` / `MAIL_PASSWORD` | build result mail |

Note that the SSH and OpenRepo secrets the `.deb` workflow needs are **not**
referenced here. Nothing in this pipeline touches the download host.

**The Docker Hub repository must exist before the first push.** It is not
auto-created in this account — an absent repository produces a failed push, not
a new repository. Create `reborns/nginx-rbs` on Docker Hub by hand if it is ever
recreated from scratch.

## Adding a distro

`DEBIAN_SUITE` is a build arg, so bookworm and bullseye need only a copy of the
workflow with `DEBIAN_SUITE` and the cron changed — or, better, one workflow with
a `strategy.matrix` over the three suites, which is also the fix for the three
duplicated 9 KB `.deb` workflows. Revisit the `latest` tag first if you do.

## Adding arm64

The deb pipeline is amd64-only, so this image matches it. To extend: add
`linux/arm64` to `platforms`, run the build on an arm64 runner (or accept QEMU
emulation, which roughly triples the OpenSSL compile), and push a manifest list.
The Dockerfile itself needs no changes — the runtime dependency detection is
architecture-agnostic.
