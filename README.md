[![Build Nginx Trixie](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-trixie-rbs.yml/badge.svg)](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-trixie-rbs.yml) \
[![Build Nginx Bookworm](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-bookworm-rbs.yml/badge.svg)](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-bookworm-rbs.yml) \
[![Build Nginx Ubuntu Noble](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-noble-rbs.yml/badge.svg)](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-noble-rbs.yml) \
[![Build Nginx Ubuntu Resolute](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-resolute-rbs.yml/badge.svg)](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-resolute-rbs.yml) \
[![Build Nginx Docker Trixie](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-docker-trixie-rbs.yml/badge.svg)](https://github.com/Reborns/nginx-rbs/actions/workflows/nginx-docker-trixie-rbs.yml)

# nginx-rbs

Custom builds of **nginx mainline** for Debian and Ubuntu, packaged as `.deb` and as a container image.
Each build is statically linked against the latest **OpenSSL 3.x** and ships extra modules
that the stock nginx.org packages don't include.

New packages are built automatically when a new nginx mainline version is released.

## Download

All current packages are available at **https://dl.schizoid.cc/utils/webservers/nginx/**

| Distribution             | Package                                    | Arch  |
| ------------------------ | ------------------------------------------ | ----- |
| Debian 13 trixie         | `nginx_<version>-1~rbs~trixie_amd64.deb`   | amd64 |
| Debian 12 bookworm       | `nginx_<version>-1~rbs~bookworm_amd64.deb` | amd64 |
| Ubuntu 26.04 resolute    | `nginx_<version>-1~rbs~resolute_amd64.deb` | amd64 |
| Ubuntu 24.04 noble       | `nginx_<version>-1~rbs~noble_amd64.deb`    | amd64 |

The download page always holds only the newest build for each distribution.
The same `.deb` files are also attached to every [release](https://github.com/Reborns/nginx-rbs/releases)
(`<version>-trixie`, `<version>-bookworm`, `<version>-resolute`, `<version>-noble`).

## Install

```bash
# pick the file for your distribution from the download page
wget https://dl.schizoid.cc/utils/webservers/nginx/nginx_<version>-1~rbs~trixie_amd64.deb
sudo apt install ./nginx_<version>-1~rbs~trixie_amd64.deb
```

`apt install ./file.deb` resolves the runtime dependencies automatically.
The package replaces nginx from nginx.org and keeps the standard layout
(`/etc/nginx`, `/usr/lib/nginx/modules`, systemd unit `nginx.service`).

## What's included

**TLS**
- OpenSSL 3.x (latest release, built in) with kTLS, threads, zlib, zstd and brotli enabled
- HTTP/2 and HTTP/3 (QUIC)

**Built-in modules**
- [headers-more](https://github.com/openresty/headers-more-nginx-module)
- [dav-ext](https://github.com/arut/nginx-dav-ext-module)
- [brotli](https://github.com/google/ngx_brotli) — `brotli` (on-the-fly) and `brotli_static` (pre-compressed `.br` files)
- All standard nginx.org modules: realip, auth_request, sub, slice, secure_link, gzip_static, mp4, stream (ssl, ssl_preread, realip), mail, and more

**Dynamic modules** (installed in `/usr/lib/nginx/modules`, load only what you need)

| Module | File |
| ------ | ---- |
| [Phusion Passenger](https://github.com/phusion/passenger) | `ngx_http_passenger_module.so` |
| [VTS (vhost traffic status)](https://github.com/vozlt/nginx-module-vts) | `ngx_http_vhost_traffic_status_module.so` |
| [GeoIP2](https://github.com/leev/ngx_http_geoip2_module) | `ngx_http_geoip2_module.so`, `ngx_stream_geoip2_module.so` |
| [Auth JWT](https://github.com/TeslaGov/ngx-http-auth-jwt-module) | `ngx_http_auth_jwt_module.so` |
| [njs](https://github.com/nginx/njs) | `ngx_http_js_module.so`, `ngx_stream_js_module.so` |

Load them at the top of `/etc/nginx/nginx.conf`, for example:

```nginx
load_module modules/ngx_http_vhost_traffic_status_module.so;
load_module modules/ngx_http_geoip2_module.so;
```

An example Passenger config is installed as `/etc/nginx/conf.d/passenger.conf.example`.

## Container image

A Debian trixie image with the same modules and OpenSSL build is published on Docker Hub:

```bash
docker pull reborns/nginx-rbs:latest
# or a specific version
docker pull reborns/nginx-rbs:<version>-trixie
```

The image runs as the non-root `nginx` user (amd64 only).
