# Shared code-signing helpers for install.sh and release.sh.
# Adapted from NoahCLR/homebrew-tap templates/signing-common.sh (see the
# backport rule in that repo's templates/README.md).
#
# Expects ROOT_DIR to be set by the sourcing script.
# ensure_signing_identity resolves SIGNING_IDENTITY; sign_app_bundle applies it.
# Override the identity per invocation with BAMBUCAM_SIGNING_IDENTITY.

SIGNING_IDENTITY="${BAMBUCAM_SIGNING_IDENTITY:-}"
LOCAL_SIGNING_IDENTITY="${BAMBUCAM_LOCAL_SIGNING_IDENTITY:-BambuCam Local Code Signing}"
SIGNING_DIR="$HOME/Library/Application Support/BambuCam/Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_exists() {
  local identity="$1"
  security find-identity -v -p codesigning 2>/dev/null | awk -F '"' -v name="$identity" '$2 == name { found = 1 } END { exit found ? 0 : 1 }'
}

create_local_signing_identity() {
  mkdir -p "$SIGNING_DIR"

  local key_file="$SIGNING_DIR/local-code-signing.key.pem"
  local rsa_key_file="$SIGNING_DIR/local-code-signing.key.rsa.pem"
  local cert_file="$SIGNING_DIR/local-code-signing.cert.pem"
  local openssl_config="$SIGNING_DIR/local-code-signing.openssl.cnf"

  if [[ ! -f "$key_file" || ! -f "$cert_file" ]]; then
    cat > "$openssl_config" <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = distinguished_name
x509_extensions = certificate_extensions

[ distinguished_name ]
CN = $LOCAL_SIGNING_IDENTITY

[ certificate_extensions ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

    openssl req \
      -new \
      -x509 \
      -newkey rsa:2048 \
      -sha256 \
      -days 3650 \
      -nodes \
      -keyout "$key_file" \
      -out "$cert_file" \
      -config "$openssl_config" >/dev/null 2>&1

    chmod 600 "$key_file"
  fi

  # Import key + cert as PEMs. The PKCS12 route fails on macOS: security(1)
  # rejects LibreSSL p12 exports with "MAC verification failed" regardless of
  # password. The key must be in traditional RSA form for security import;
  # OpenSSL 3 (e.g. Homebrew's, shadowing /usr/bin) writes PKCS#8 by default,
  # which security import rejects with "Unknown format in import".
  openssl rsa -in "$key_file" -out "$rsa_key_file" >/dev/null 2>&1
  if grep -q "BEGIN PRIVATE KEY" "$rsa_key_file"; then
    openssl rsa -traditional -in "$key_file" -out "$rsa_key_file" >/dev/null 2>&1
  fi
  chmod 600 "$rsa_key_file"

  security import "$rsa_key_file" -k "$LOGIN_KEYCHAIN" -t priv -f openssl -A >/dev/null 2>&1 || true
  security import "$cert_file" -k "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
  security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$cert_file" >/dev/null 2>&1 || true
}

ensure_signing_identity() {
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    if identity_exists "$SIGNING_IDENTITY"; then
      echo "Using requested signing identity: $SIGNING_IDENTITY"
      return
    fi

    echo "Requested signing identity was not found: $SIGNING_IDENTITY" >&2
    echo "Run 'security find-identity -v -p codesigning' to see available identities." >&2
    exit 1
  fi

  # Default to the neutral self-signed identity: it embeds no Apple ID email in
  # the signature, and Gatekeeper treats unnotarized apps the same regardless of
  # certificate. Set BAMBUCAM_SIGNING_IDENTITY to use a different identity.
  SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
  if identity_exists "$SIGNING_IDENTITY"; then
    echo "Using local signing identity: $SIGNING_IDENTITY"
    return
  fi

  echo "Creating local code signing identity: $SIGNING_IDENTITY"
  create_local_signing_identity

  if ! identity_exists "$SIGNING_IDENTITY"; then
    echo "Could not create a valid local code signing identity." >&2
    echo "Create a Code Signing certificate named '$SIGNING_IDENTITY' in Keychain Access, then rerun this script." >&2
    exit 1
  fi
}

sign_app_bundle() {
  local app_path="$1"

  echo "Applying stable signature: $SIGNING_IDENTITY"
  find "$app_path/Contents" -type f -name "*.dylib" -print0 | while IFS= read -r -d '' binary; do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$binary"
  done

  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$app_path"
  codesign --verify --deep --strict "$app_path"
}
