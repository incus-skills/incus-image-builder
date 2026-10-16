#!/usr/bin/env bash

#
# build-devuan-image.sh
#
# Build a Devuan Incus container image with distrobuilder.
#
# Produces:
#   incus.tar.xz
#   rootfs.squashfs
#   image.yaml
#   build.log
#   build-metadata.json
#   SHA256SUMS
#   *.asc
#   optional *.delta and *.delta.asc
#
# Usage:
#   ./build-devuan-image.sh \
#   [DISTRO] [RELEASE] [ARCH] [VARIANT] \
#   [SOURCE_URL] [COMPONENTS] [USE_SNAPSHOT]
#
# Environment:
#   GPG_PASSPHRASE Required.
#   IMAGE_OUTPUT_ROOT Optional. Default: /var/tmp/incus-images
#   GIT_COMMIT_SHA Optional. Added to build metadata.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

DISTRO="${1:-devuan}"
RELEASE="${2:-freia}"
ARCH="${3:-amd64}"
VARIANT="${4:-default}"
SOURCE_URL="${5:-https://pkgmaster.devuan.org/merged/}"
COMPONENTS="${6:-main contrib non-free non-free-firmware}"
USE_SNAPSHOT="${7:-no}"

EMAIL="incus.images@ring-zero.co.uk"
IMAGE_OUTPUT_ROOT="${IMAGE_OUTPUT_ROOT:-/var/tmp/incus-images}"
GIT_COMMIT_SHA="${GIT_COMMIT_SHA:-unknown}"

case "${RELEASE}" in
freia)
  DEBIAN_RELEASE="forky"
  ;;
ceres)
  DEBIAN_RELEASE="sid"
  ;;
excalibur)
  DEBIAN_RELEASE="trixie"
  ;;
*)
  echo "ERROR: unknown release '${RELEASE}'. Expected freia, ceres, or excalibur." >&2
  exit 1
  ;;
esac

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

BASE_OUTPUT_DIR="${IMAGE_OUTPUT_ROOT}/images/${DISTRO}/${RELEASE}/${ARCH}/${VARIANT}"
TARGET_DIR="${BASE_OUTPUT_DIR}/${TIMESTAMP}"
BUILD_LOG="${TARGET_DIR}/build.log"

# ──────────────────────────────────────────────────────────────────────────────
# Preconditions
# ──────────────────────────────────────────────────────────────────────────────

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: this script must run as root." >&2
  exit 1
fi

: "${GPG_PASSPHRASE:?GPG_PASSPHRASE is not set}"

for tool in curl jq yq gpg distrobuilder sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: required tool not found: ${tool}" >&2
    exit 1
  }
done

if [[ -d "${TARGET_DIR}" && -n "$(ls -A "${TARGET_DIR}" 2>/dev/null)" ]]; then
  echo "ERROR: output directory already exists and is not empty: ${TARGET_DIR}" >&2
  exit 1
fi

mkdir -p "${TARGET_DIR}"

echo "==> Building ${DISTRO} ${RELEASE} (${ARCH}) variant=${VARIANT}"
echo "==> Source: ${SOURCE_URL}"
echo "==> Components: ${COMPONENTS}"
echo "==> Snapshot: ${USE_SNAPSHOT}"
echo "==> Output: ${TARGET_DIR}"

# ──────────────────────────────────────────────────────────────────────────────
# GPG signing key
# ──────────────────────────────────────────────────────────────────────────────

if ! gpg --list-secret-keys --with-colons "${EMAIL}" 2>/dev/null |
  grep -q '^sec:'; then
  echo "ERROR: no GPG secret key found for ${EMAIL}." >&2
  echo "Import the long-lived image-signing private key before building." >&2
  exit 1
fi

GPG_KEY_ID="$(
  gpg --list-secret-keys --with-colons "${EMAIL}" |
    awk -F: '/^fpr:/ { print $10; exit }'
)"

if [[ -z "${GPG_KEY_ID}" ]]; then
  echo "ERROR: unable to determine GPG key fingerprint." >&2
  exit 1
fi

echo "==> Using GPG key: ${GPG_KEY_ID}"

sign_file() {
  local file="$1"

  printf '%s' "${GPG_PASSPHRASE}" |
    gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 \
      --local-user "${GPG_KEY_ID}" \
      --armor --detach-sign \
      --output "${file}.asc" \
      "${file}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Download and modify lxc-ci image definition
# ──────────────────────────────────────────────────────────────────────────────

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

YAML_FILE="${WORK_DIR}/${DISTRO}.yaml"

echo "==> Downloading lxc-ci image definition..."

curl -fsSL \
  -o "${YAML_FILE}" \
  "https://raw.githubusercontent.com/lxc/lxc-ci/main/images/${DISTRO}.yaml"

echo "==> Adding debian-archive-keyring to early package set..."

yq -yi \
  --arg keyring "debian-archive-keyring" \
  '.packages.sets[0].packages += [$keyring]' \
  "${YAML_FILE}"

echo "==> Configuring Devuan repositories..."

cat >"${WORK_DIR}/devuan_repo.txt" <<EOF
deb [check-valid-until=no signed-by=/usr/share/keyrings/devuan-archive-keyring.pgp] ${SOURCE_URL} {{ image.release }} ${COMPONENTS}
deb [check-valid-until=no signed-by=/usr/share/keyrings/devuan-archive-keyring.pgp] ${SOURCE_URL} {{ image.release }}-security ${COMPONENTS}
EOF

yq -yi \
  --rawfile devuan_repo "${WORK_DIR}/devuan_repo.txt" \
  '.packages.repositories = [{name: "devuan", url: $devuan_repo}]' \
  "${YAML_FILE}"

# ──────────────────────────────────────────────────────────────────────────────
# Optional Debian snapshot repositories
# ──────────────────────────────────────────────────────────────────────────────

SNAP_TS=""
SNAP_SEC_TS=""

if [[ "${USE_SNAPSHOT}" == "yes" ]]; then
  echo "==> Generating snapshot.debian.org timestamps..."

  SNAP_TS="$(date -u -d '1 hour ago' +%Y%m%dT%H%M%SZ)"
  SNAP_SEC_TS="${SNAP_TS}"

  echo "==> Snapshot: debian=${SNAP_TS}, debian-security=${SNAP_SEC_TS}"
  cat >"${WORK_DIR}/snapshot_repo.txt" <<EOF
deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.pgp] https://snapshot.debian.org/archive/debian/${SNAP_TS}/ ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.pgp] https://snapshot.debian.org/archive/debian-security/${SNAP_SEC_TS}/ ${DEBIAN_RELEASE}/updates main contrib non-free non-free-firmware
EOF

  yq -yi \
    --rawfile snap_repo "${WORK_DIR}/snapshot_repo.txt" \
    '.packages.repositories += [{name: "debian-snapshot", url: $snap_repo}]' \
    "${YAML_FILE}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Post-packages action
# ──────────────────────────────────────────────────────────────────────────────

echo "==> Updating post-packages action..."

cat >"${WORK_DIR}/post-packages.sh" <<'EOF'
#!/bin/sh
set -eux

# inittab if missing

[ ! -e "/etc/inittab" ] && cp /usr/share/sysvinit/inittab /etc/inittab

# Fix container shutdown

sed -i "s#^pf::powerwait.*#pf::powerwait:/sbin/poweroff#" /etc/inittab

# Disable gettys

sed -i '/tty[1-6]/s/^/#/' /etc/inittab

# Ensure locale is built and functional

echo en_US.UTF-8 UTF-8 >> /etc/locale.gen
locale-gen en_US.UTF-8 UTF-8
update-locale LANG=en_US.UTF-8

# Fix cloud-init postinst configuration

if [ -f /etc/init.d/cloud-init-main ]; then
if [ -f /etc/init.d/cloud-config ]; then
sed -i \
"s/remote_fs cloud-init cloud-init-local/remote_fs cloud-init-main cloud-init-local/" \
/etc/init.d/cloud-config
update-rc.d cloud-config defaults
update-rc.d cloud-final defaults
fi
fi

# Prefer Debian snapshot repositories when configured

if [ -d /etc/apt/preferences.d ]; then
cat > /etc/apt/preferences.d/99-debian-snapshot <<PREF
Package: *
Pin: origin "snapshot.debian.org"
Pin-Priority: 900
PREF
fi

# Clean transient runtime contents

mount -o bind / /mnt
rm -rf /mnt/run/*
umount /mnt

# Remove temporary shadow files

rm -f /etc/*-
EOF

yq -yi \
  --rawfile action "${WORK_DIR}/post-packages.sh" \
  '(.actions[] | select(.trigger == "post-packages") | .action) = $action' \
  "${YAML_FILE}"

if ! yq -r \
  '.actions[] | select(.trigger == "post-packages") | .action' \
  "${YAML_FILE}" | grep -q '^#!/bin/sh'; then
  echo "ERROR: failed to update post-packages action." >&2
  exit 1
fi

yq -yi \
  --arg url "${SOURCE_URL}" \
  '.source.url = $url' \
  "${YAML_FILE}"

cp "${YAML_FILE}" "${TARGET_DIR}/image.yaml"

# ──────────────────────────────────────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────────────────────────────────────

echo "==> Running distrobuilder build-incus..."

distrobuilder build-incus \
  "${YAML_FILE}" \
  "${TARGET_DIR}" \
  -o "image.architecture=${ARCH}" \
  -o "image.release=${RELEASE}" \
  -o "image.variant=${VARIANT}" \
  --disable-overlay \
  2>&1 | tee "${BUILD_LOG}"

# ──────────────────────────────────────────────────────────────────────────────
# Validate artifacts
# ──────────────────────────────────────────────────────────────────────────────

echo "==> Verifying build output..."

for file in incus.tar.xz rootfs.squashfs; do
  if [[ ! -f "${TARGET_DIR}/${file}" ]]; then
    echo "ERROR: expected output file not found: ${TARGET_DIR}/${file}" >&2
    exit 1
  fi
done

echo "==> All expected image files present."

# ──────────────────────────────────────────────────────────────────────────────
# Build metadata
# ──────────────────────────────────────────────────────────────────────────────

cat >"${TARGET_DIR}/build-metadata.json" <<EOF
{
"timestamp": "${TIMESTAMP}",
"git_commit_sha": "${GIT_COMMIT_SHA}",
"distro": "${DISTRO}",
"release": "${RELEASE}",
"debian_release": "${DEBIAN_RELEASE}",
"arch": "${ARCH}",
"variant": "${VARIANT}",
"source_url": "${SOURCE_URL}",
"components": "${COMPONENTS}",
"use_snapshot": "${USE_SNAPSHOT}",
"snap_ts": "${SNAP_TS}",
"snap_sec_ts": "${SNAP_SEC_TS}"
}
EOF

# ──────────────────────────────────────────────────────────────────────────────
# Checksums and signatures
# ──────────────────────────────────────────────────────────────────────────────

echo "==> Generating SHA256SUMS..."

cd "${TARGET_DIR}"

SIGNED_FILES=(
  incus.tar.xz
  rootfs.squashfs
  image.yaml
  build.log
  build-metadata.json
)

sha256sum "${SIGNED_FILES[@]}" >SHA256SUMS

echo "==> Signing artifacts..."

for file in "${SIGNED_FILES[@]}" SHA256SUMS; do
  sign_file "${file}"
done

# ──────────────────────────────────────────────────────────────────────────────
# Optional deltas
# ──────────────────────────────────────────────────────────────────────────────

echo "==> Looking for a compatible previous build..."

PREV_DIR="$(
  find "${BASE_OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d \
    ! -path "${TARGET_DIR}" |
    sort -r |
    head -n 1
)"

if [[ -n "${PREV_DIR}" ]]; then
  if [[ ! -f "${PREV_DIR}/rootfs.squashfs" ]] ||
    [[ ! -f "${PREV_DIR}/incus.tar.xz" ]] ||
    [[ ! -f "${PREV_DIR}/build-metadata.json" ]]; then
    echo "==> Previous build is incomplete; skipping delta generation."
    PREV_DIR=""
  fi
fi

if [[ -n "${PREV_DIR}" ]]; then
  PREV_METADATA="${PREV_DIR}/build-metadata.json"

  PREV_USE_SNAPSHOT="$(jq -r '.use_snapshot // ""' "${PREV_METADATA}")"
  PREV_SNAP_TS="$(jq -r '.snap_ts // ""' "${PREV_METADATA}")"
  PREV_SNAP_SEC_TS="$(jq -r '.snap_sec_ts // ""' "${PREV_METADATA}")"
  PREV_DEBIAN_RELEASE="$(jq -r '.debian_release // ""' "${PREV_METADATA}")"
  PREV_ARCH="$(jq -r '.arch // ""' "${PREV_METADATA}")"

  if [[ "${PREV_USE_SNAPSHOT}" != "${USE_SNAPSHOT}" ]] ||
    [[ "${PREV_SNAP_TS}" != "${SNAP_TS}" ]] ||
    [[ "${PREV_SNAP_SEC_TS}" != "${SNAP_SEC_TS}" ]] ||
    [[ "${PREV_DEBIAN_RELEASE}" != "${DEBIAN_RELEASE}" ]] ||
    [[ "${PREV_ARCH}" != "${ARCH}" ]]; then
    echo "==> Previous build parameters differ; skipping delta generation."
    PREV_DIR=""
  fi
fi

if [[ -n "${PREV_DIR}" ]]; then
  echo "==> Generating deltas against ${PREV_DIR}"

  command -v xdelta3 >/dev/null 2>&1 || {
    echo "ERROR: xdelta3 not found." >&2
    exit 1
  }

  xdelta3 -e -s \
    "${PREV_DIR}/rootfs.squashfs" \
    "${TARGET_DIR}/rootfs.squashfs" \
    "${TARGET_DIR}/rootfs.squashfs.delta"

  xdelta3 -e -s \
    "${PREV_DIR}/incus.tar.xz" \
    "${TARGET_DIR}/incus.tar.xz" \
    "${TARGET_DIR}/incus.tar.xz.delta"

  DELTA_FILES=(
    rootfs.squashfs.delta
    incus.tar.xz.delta
  )

  sha256sum "${DELTA_FILES[@]}" >>SHA256SUMS

  for file in "${DELTA_FILES[@]}"; do
    sign_file "${file}"
  done

  sign_file SHA256SUMS

  echo "==> Deltas generated and signed."
else
  echo "==> No compatible previous build; skipping delta generation."
fi

echo "==> Build complete: ${TARGET_DIR}"
