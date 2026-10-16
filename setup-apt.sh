#!/usr/bin/env bash
#
# Adds the nginx-rbs apt repository on Debian 12/13 and Ubuntu 24.04/26.04.
#
#   curl -fsSL https://raw.githubusercontent.com/Reborns/nginx-rbs/master/setup-apt.sh | sudo bash
#   sudo apt install nginx
#
# Writes three files, the same on every distribution:
#   /etc/apt/keyrings/nginx-rbs.asc             repo signing key (ASCII-armored)
#   /etc/apt/sources.list.d/nginx-rbs.sources   repo, deb822 format
#   /etc/apt/preferences.d/nginx-rbs            pin: prefer nginx-rbs over nginx.org / distro nginx
#

set -euo pipefail

APT_HOST="${APT_HOST:-https://apt.schizoid.cc}"
SUPPORTED="bookworm trixie noble resolute"

KEY=/etc/apt/keyrings/nginx-rbs.asc
SOURCES=/etc/apt/sources.list.d/nginx-rbs.sources
PIN=/etc/apt/preferences.d/nginx-rbs

die() { echo "nginx-rbs: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (pipe into 'sudo bash')"
[ -r /etc/os-release ] || die "/etc/os-release not found"

# Ubuntu derivatives (Mint, Pop!_OS, ...) report their Ubuntu base in UBUNTU_CODENAME.
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
case " $SUPPORTED " in
  *" $CODENAME "*) ;;
  *) die "unsupported release '${CODENAME:-unknown}' (supported: $SUPPORTED)" ;;
esac

REPO_URL="${APT_HOST%/}/$CODENAME/"
# Pin by bare hostname: strip scheme, port and path.
ORIGIN="$(echo "$APT_HOST" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"

echo "nginx-rbs: setting up $REPO_URL for $CODENAME"

if ! command -v curl >/dev/null 2>&1 || [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl >/dev/null
fi

install -m 0755 -d /etc/apt/keyrings
tmpkey="$(mktemp)"
trap 'rm -f "$tmpkey"' EXIT
curl -fsSL "${REPO_URL}public.gpg" -o "$tmpkey" \
  || die "could not download ${REPO_URL}public.gpg"
grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$tmpkey" \
  || die "${REPO_URL}public.gpg is not an ASCII-armored PGP key"
install -m 0644 "$tmpkey" "$KEY"

rm -f "/etc/apt/sources.list.d/openrepo-$CODENAME.list" \
      "/usr/share/keyrings/openrepo-$CODENAME.gpg" \
      /etc/apt/sources.list.d/nginx-rbs.list

cat > "$SOURCES" <<EOF
Types: deb
URIs: $REPO_URL
Suites: stable
Components: main
Architectures: any
Signed-By: $KEY
EOF

cat > "$PIN" <<EOF
Package: nginx*
Pin: origin $ORIGIN
Pin-Priority: 1001
EOF

chmod 0644 "$SOURCES" "$PIN"

apt-get update -qq

CANDIDATE="$(apt-cache policy nginx | awk '/Candidate:/{print $2}')"
case "$CANDIDATE" in
  *~rbs~"$CODENAME") echo "nginx-rbs: ready, candidate nginx $CANDIDATE. Install with: apt install nginx" ;;
  *) die "repo added, but the nginx candidate is '${CANDIDATE:-none}', not an rbs build; see 'apt-cache policy nginx'" ;;
esac
