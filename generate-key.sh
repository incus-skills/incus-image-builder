#!/usr/bin/env bash
set -euo pipefail

EMAIL="incus.images@ring-zero.co.uk"
NAME="Incus Image Builder"
OUTPUT="../incus-image-signing-private-key.asc"
OUTPUT2="../incus-image-signing-private-passphrase"

GPG_PASSPHRASE="$(shuf -n 4 /usr/share/dict/words | tr '\n' ' ' | sed 's/ $//')$(head -c 16 <(tr -dc 'A-Za-z0-9' </dev/urandom))"
echo "${GPG_PASSPHRASE}" >"../${OUTPUT2}"

PASSPHRASE="${GPG_PASSPHRASE:?Set GPG_PASSPHRASE env var (must be a strong passphrase)}"

PARAMS=$(mktemp)
trap 'rm -f "$PARAMS"' EXIT

# --- Batch key generation: ECC (sign and encrypt) ---
cat >"$PARAMS" <<EOF
%echo Generating ECC (sign and encrypt) key for $EMAIL
Key-Type: EDDSA
Key-Curve: Ed25519
Key-Usage: sign,cert
Subkey-Type: ECDH
Subkey-Curve: Curve25519
Subkey-Usage: encrypt
Name-Real: $NAME
Name-Email: $EMAIL
Expire-Date: 0
Passphrase: $PASSPHRASE
%commit
%echo Key generated successfully
EOF

# --- Generate key ---
gpg --batch --gen-key "$PARAMS"

# --- Export secret key (armored) ---
gpg --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" \
  --armor --export-secret-keys --output "$OUTPUT" "$EMAIL"

# --- Verify the exported file ---
echo "Verifying exported key..."
gpg --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" \
  --dry-run --import "$OUTPUT"

# --- Show first line as sanity check ---
echo "First line: $(head -n 1 "$OUTPUT")"
echo ""
echo "Secret key exported to: $OUTPUT"
echo "Secret passphrase exported to: $OUTPUT2"
echo "Paste its full contents into Forgejo → Settings → Actions → Secrets → INCUS_IMAGE_GPG_PRIVATE_KEY"
echo "Paste its full contents into Forgejo → Settings → Actions → Secrets → INCUS_IMAGE_GPG_PASSPHRASE"
