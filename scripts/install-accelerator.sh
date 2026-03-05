#!/usr/bin/env bash
# scripts/install-accelerator.sh — download shepard-hook to hooks/bin/
#
# Usage:
#   ./scripts/install-accelerator.sh              # latest release
#   ./scripts/install-accelerator.sh v0.1.0       # specific version
#
# No sudo required — binary lives inside the project.

set -euo pipefail

REPO="shepard-system/shepard-hooks-rs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/../hooks/bin"

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }

# Detect OS
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  linux|darwin) ;;
  *) red "Unsupported OS: $os"; exit 1 ;;
esac

# Detect arch
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch="x64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) red "Unsupported arch: $arch"; exit 1 ;;
esac

# Resolve version
version="${1:-latest}"
if [[ "$version" == "latest" ]]; then
  version=$(curl -sfL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  if [[ -z "$version" ]]; then
    red "No releases found at ${REPO}"
    exit 1
  fi
fi

platform="$os"
[[ "$os" == "darwin" ]] && platform="macos"
asset="shepard-hook-${platform}-${arch}.tar.gz"
download_url="https://github.com/${REPO}/releases/download/${version}/${asset}"
sha_url="https://github.com/${REPO}/releases/download/${version}/SHA256SUMS"

echo "Installing shepard-hook ${version} (${os}/${arch})..."

# Download to temp
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

if ! curl -sfL -o "${tmp_dir}/${asset}" "$download_url"; then
  red "Download failed: ${download_url}"
  exit 1
fi

# Verify SHA256
if curl -sfL -o "${tmp_dir}/SHA256SUMS" "$sha_url" 2>/dev/null; then
  expected=$(grep "$asset" "${tmp_dir}/SHA256SUMS" | awk '{print $1}')
  if [[ -n "$expected" ]]; then
    if command -v sha256sum &>/dev/null; then
      actual=$(sha256sum "${tmp_dir}/${asset}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
      actual=$(shasum -a 256 "${tmp_dir}/${asset}" | awk '{print $1}')
    fi

    if [[ -n "${actual:-}" && "$expected" != "$actual" ]]; then
      red "SHA256 mismatch!"
      red "  Expected: $expected"
      red "  Got:      $actual"
      exit 1
    fi
    green "SHA256 verified"
  fi
else
  yellow "SHA256SUMS not available — skipping verification"
fi

# Extract and install
mkdir -p "$INSTALL_DIR"
tar xzf "${tmp_dir}/${asset}" -C "$tmp_dir"
mv "${tmp_dir}/shepard-hook-${platform}-${arch}" "${INSTALL_DIR}/shepard-hook"
chmod +x "${INSTALL_DIR}/shepard-hook"

green "shepard-hook ${version} → ${INSTALL_DIR}/shepard-hook"
"${INSTALL_DIR}/shepard-hook" --version 2>/dev/null || true
