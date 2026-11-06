#!/usr/bin/env bash
# One-line installer entry point for DDK VPS Manager.
set -Eeuo pipefail

REPOSITORY="mrshahnawazyt/DDK-VPS-Manager"
ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/refs/heads/main.zip"
WORK_DIR="$(mktemp -d /tmp/ddk-vps-manager.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this command with sudo."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip
  else
    echo "curl and unzip are required on this operating system."
    exit 1
  fi
fi

echo "Downloading DDK VPS Manager..."
curl --fail --location --retry 3 --silent --show-error "$ARCHIVE_URL" -o "$WORK_DIR/source.zip"
unzip -q "$WORK_DIR/source.zip" -d "$WORK_DIR"

SOURCE_DIR="$WORK_DIR/DDK-VPS-Manager-main"
if [[ ! -f "$SOURCE_DIR/install.sh" ]]; then
  echo "Downloaded project files are incomplete. Installation stopped."
  exit 1
fi

bash "$SOURCE_DIR/install.sh"
