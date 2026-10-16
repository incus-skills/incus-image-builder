#!/usr/bin/env bash

#
# publish-simplestreams.sh
#
# Adds a validated split Incus image to a persistent simplestreams tree,
# verifies the tree, signs its index files, and atomically publishes it.
#
# Run this on the image-publishing host, not in the ephemeral CI job.
#
# Required environment:
# IMAGE_DIR Directory containing incus.tar.xz and rootfs.squashfs
# GPG_PASSPHRASE Signing passphrase
#
# Optional environment:
# SIMPLESTREAMS_ROOT Default: /srv/incus-images
# PUBLISH_ROOT Default: /srv/incus-images-public
# GPG_EMAIL Default: incus.images@ring-zero.co.uk
set -euo pipefail

: "${IMAGE_DIR:?IMAGE_DIR is not set}"
: "${GPG_PASSPHRASE:?GPG_PASSPHRASE is not set}"

GPG_EMAIL="${GPG_EMAIL:-incus.images@ring-zero.co.uk}"
SIMPLESTREAMS_ROOT="${SIMPLESTREAMS_ROOT:-/srv/incus-images}"
PUBLISH_ROOT="${PUBLISH_ROOT:-/srv/incus-images-public}"

METADATA_FILE="${IMAGE_DIR}/incus.tar.xz"
DATA_FILE="${IMAGE_DIR}/rootfs.squashfs"

for file in "${METADATA_FILE}" "${DATA_FILE}"; do
[[ -f "${file}" ]] || {
echo "ERROR: required image file missing: ${file}" >&2
exit 1
}
done

for tool in gpg incus-simplestreams rsync; do
command -v "$tool" >/dev/null 2>&1 || {
echo "ERROR: required tool not found: ${tool}" >&2
exit 1
}
done

GPG_KEY_ID="$(
gpg --list-secret-keys --with-colons "${GPG_EMAIL}" \
| awk -F: '/^fpr:/ { print $10; exit }'
)"

[[ -n "${GPG_KEY_ID}" ]] || {
echo "ERROR: no GPG key found for ${GPG_EMAIL}" >&2
exit 1
}

sign_file() {
local file="$1"

printf '%s' "${GPG_PASSPHRASE}" \
| gpg --batch --yes --pinentry-mode loopback \
--passphrase-fd 0 \
--local-user "${GPG_KEY_ID}" \
--armor --detach-sign \
--output "${file}.asc" \
"${file}"
}

echo "==> Adding image to simplestreams staging tree..."

incus-simplestreams add \
--dir "${SIMPLESTREAMS_ROOT}" \
"${METADATA_FILE}" \
"${DATA_FILE}"

echo "==> Verifying simplestreams tree..."

incus-simplestreams verify --dir "${SIMPLESTREAMS_ROOT}"

echo "==> Signing simplestreams index files..."

for index_file in \
"${SIMPLESTREAMS_ROOT}/streams/v1/index.json" \
"${SIMPLESTREAMS_ROOT}/streams/v1/images.json"; do
if [[ -f "${index_file}" ]]; then
sign_file "${index_file}"
fi
done

echo "==> Atomically publishing tree..."

STAGING_PUBLISH="${PUBLISH_ROOT}.staging.$$"
FINAL_PUBLISH="${PUBLISH_ROOT}"

rm -rf "${STAGING_PUBLISH}"
mkdir -p "$(dirname "${FINAL_PUBLISH}")" "${STAGING_PUBLISH}"

rsync -a --delete \
"${SIMPLESTREAMS_ROOT}/" \
"${STAGING_PUBLISH}/"

if [[ -d "${FINAL_PUBLISH}" ]]; then
mv "${FINAL_PUBLISH}" "${FINAL_PUBLISH}.previous.$$"
fi

mv "${STAGING_PUBLISH}" "${FINAL_PUBLISH}"

rm -rf "${FINAL_PUBLISH}".previous.* 2>/dev/null || true

echo "==> Published simplestreams tree: ${FINAL_PUBLISH}"

incus-simplestreams list --dir "${FINAL_PUBLISH}"
