#!/usr/bin/env bash
# Install the barndoor CLI from Barndoor's release index, verifying the
# published SHA-256 before anything is made executable.
#
#   scripts/install-barndoor-cli.sh                 latest release -> ~/.local/bin
#   scripts/install-barndoor-cli.sh v0.1.244        a specific release
#   INSTALL_DIR=/usr/local/bin scripts/install-barndoor-cli.sh
set -euo pipefail

INDEX_URL="https://downloads.barndoor.ai/barndoor-cli/index.json"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
version="${1:-}"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

index="$(curl -fsSL "$INDEX_URL")"
read -r version asset sha256 < <(VERSION="$version" OS="$os" ARCH="$arch" python3 -c '
import json, os, sys
index = json.load(sys.stdin)
version = os.environ["VERSION"] or index["latest"]
target_os, target_arch = os.environ["OS"], os.environ["ARCH"]
asset = f"barndoor-{version}-{target_os}-{target_arch}"
try:
    print(version, asset, index["versions"][version]["assets"][asset]["sha256"])
except KeyError:
    sys.exit(f"no {asset} in the release index")
' <<<"$index")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "→ downloading $asset"
curl -fsSL -o "$tmp/barndoor" "https://downloads.barndoor.ai/barndoor-cli/$version/$asset"

actual="$(shasum -a 256 "$tmp/barndoor" | awk '{print $1}')"
if [ "$actual" != "$sha256" ]; then
  echo "checksum mismatch for $asset: expected $sha256, got $actual" >&2
  exit 1
fi
echo "→ checksum verified"

mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp/barndoor" "$INSTALL_DIR/barndoor"
echo "→ installed $INSTALL_DIR/barndoor ($version)"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "   add $INSTALL_DIR to PATH, or set BARNDOOR_BIN=$INSTALL_DIR/barndoor in .env" ;;
esac
