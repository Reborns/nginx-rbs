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
| Static modules | `headers-more`, `dav-ext` |
| Dynamic modules | `njs` (http + stream), `VTS`, `GeoIP2` (http + stream), `auth-JWT`, `Passenger` |
| HTTP/3 | yes — `--with-http_v3_module`; `443/udp` is exposed |
| Base | `debian:trixie-slim` |
| Platform | `linux/amd64` |

## Tags

| Tag | Moves? |
|---|---|
| `1.29.5-openssl3.6.1-trixie` | no — immutable, pins both versions |
| `1.29.5-trixie` | yes, on an OpenSSL-only rebuild |
| `1.29-trixie` | yes |
| `trixie` | yes |
| `latest` | yes |

Pin the immutable tag in production. The `1.29.5-trixie` tag deliberately moves
when OpenSSL alone is bumped, so you can follow security rebuilds without a
version change.

## Dynamic modules

Loaded via snippets in `/etc/nginx/modules-available/`, enabled by symlink into
`/etc/nginx/modules-enabled/`. Everything is enabled by default **except
Passenger**, because loading the Passenger module starts its watchdog and agent
processes in every container whether or not you serve a Ruby app.

To turn Passenger on:

```dockerfile
FROM reborns/nginx-rbs:trixie
RUN ln -sf /etc/nginx/modules-available/50-http-passenger.conf \
           /etc/nginx/modules-enabled/50-http-passenger.conf
COPY passenger.conf /etc/nginx/conf.d/passenger.conf
```

`/etc/nginx/conf.d/passenger.conf.example` in the image already has the correct
`passenger_root` and `passenger_ruby` substituted in.

To turn a module off, remove its symlink. `default.conf` is intentionally free of
module-specific directives so that removing one never breaks startup.

## Provenance

Every image carries `/usr/share/nginx-rbs/module-commits.txt` — the exact commit
SHA of each third-party module and the OpenSSL and Passenger versions that went
in. Module refs default to floating HEAD, matching the `.deb` pipeline's
behaviour, so this manifest is how you find out afterwards what a given image
actually contains:

```sh
docker run --rm reborns/nginx-rbs:trixie \
  cat /usr/share/nginx-rbs/module-commits.txt
```

To pin instead, set any of the `*_REF` build args (`NJS_REF`,
`HEADERS_MORE_REF`, `DAV_EXT_REF`, `VTS_REF`, `GEOIP2_REF`, `AUTH_JWT_REF`,
`PASSENGER_VERSION`) to a tag or commit SHA.

## Building locally

Both version arguments and both digests are required; the build fails fast
rather than producing a subtly wrong image.

```sh
NGINX_VERSION=1.29.5
OPENSSL_VERSION=3.6.1

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
| `DOCKERHUB_TOKEN` | registry login — use an access token, not the account password |
| `MAIL_USERNAME` / `MAIL_PASSWORD` | build result mail |

Note that the SSH and OpenRepo secrets the `.deb` workflow needs are **not**
referenced here. Nothing in this pipeline touches the download host.

## Adding a distro

`DEBIAN_SUITE` is a build arg, so bookworm and bullseye need only a copy of the
workflow with `DEBIAN_SUITE` and the cron changed — or, better, one workflow with
a `strategy.matrix` over the three suites, which is also the fix for the three
duplicated 9 KB `.deb` workflows.

## Adding arm64

The deb pipeline is amd64-only, so this image matches it. To extend: add
`linux/arm64` to `platforms`, run the build on an arm64 runner (or accept QEMU
emulation, which roughly triples the OpenSSL compile), and push a manifest list.
The Dockerfile itself needs no changes — the runtime dependency detection is
architecture-agnostic.
