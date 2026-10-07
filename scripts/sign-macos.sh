#!/bin/bash
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Signed + notarized release packages: checks that signing is set up, then
# runs scripts/package.sh with the Developer ID identity and the notary
# credentials (the dmg is signed, notarized and stapled).
#
#   scripts/sign-macos.sh            check, then package (package.sh's
#                                    variables work: SKIP_BUILD=1 …)
#   scripts/sign-macos.sh --check    only the checks
#   GTTY_SIGN_IDENTITY, GTTY_NOTARY_PROFILE_NAME, GTTY_CERT_WARN_DAYS
#   override the identity, the profile name and the 30 days.
#
# On a Mac (no CI variables): the signing material lives outside the repo,
# in $GTTY_SIGNING_DIR (default $HOME/tmp):
#   gtty.p12              Developer ID Application certificate + private key
#   AuthKey_<KEYID>.p8    App Store Connect API key
#   gtty_key_id.txt       "Issuer Id: …" and "Key Id: …" lines
# The checks stop at the first problem and say how to fix it: the identity
# must be in the keychain, the notarytool profile gtty-notary must work;
# a certificate expiring within 30 days is a warning. Nothing from these
# files is printed except the key's ID and the Issuer ID.
#
# In CI (MACOS_CERT_P12 set; see scripts/set-github-secrets.sh) the checks
# are skipped: the certificate goes into a temporary keychain and
# notarization uses the API key from the environment:
#   MACOS_CERT_P12 (base64), MACOS_CERT_PASSWORD, KEYCHAIN_PASSWORD,
#   APPLE_API_KEY_P8 (contents), APPLE_API_KEY_ID, APPLE_API_ISSUER_ID,
#   APPLE_TEAM_ID
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${GTTY_SIGN_IDENTITY:-"Developer ID Application: Sagi Nagar (N25UN9L94Q)"}
PROFILE=${GTTY_NOTARY_PROFILE_NAME:-gtty-notary}
WARN_DAYS=${GTTY_CERT_WARN_DAYS:-30}
DIR=${GTTY_SIGNING_DIR:-$HOME/tmp}
CHECK_ONLY=0
[ "${1:-}" = --check ] && CHECK_ONLY=1

fail() {
    echo "sign-macos: $*" >&2
    exit 1
}

# Reading the API key files in $DIR. gtty_key_id.txt looks like
#   Issuer Id: 69a6…
#   Key Id: 3N…
# (labels in any case; a file with only the Issuer ID still works).
# Messages go to stderr; values are never printed here. Same as in
# set-github-secrets.sh: keep the two in step.

# The value after "<label>:" in gtty_key_id.txt, trimmed.
key_file_field() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//Ip" "$DIR/gtty_key_id.txt" | head -1 | tr -d '[:space:]'
}

# The Issuer ID (empty: not found).
key_file_issuer() {
    local v
    v=$(key_file_field 'issuer[[:space:]]*id')
    # Old format: just the ID, one word, no labels.
    if [ -z "$v" ] && ! grep -q ':' "$DIR/gtty_key_id.txt"; then
        v=$(tr -d '[:space:]' < "$DIR/gtty_key_id.txt")
    fi
    printf '%s' "$v"
}

# The one AuthKey_*.p8 in $DIR (empty: none; status 1 and a message for
# several).
key_file_p8() {
    local found=() f
    for f in "$DIR"/AuthKey_*.p8; do [ -f "$f" ] && found+=("$f"); done
    if [ ${#found[@]} -gt 1 ]; then
        echo "several API keys in $DIR (${found[*]##*/}): keep only the current AuthKey_<KEYID>.p8" >&2
        return 1
    fi
    [ ${#found[@]} -eq 1 ] && printf '%s' "${found[0]}"
    return 0
}

# The Key ID: "Key Id:" in gtty_key_id.txt, else the .p8's name
# (AuthKey_<KEYID>.p8). Status 1 and a message when the two disagree.
key_file_key_id() {
    local p8=$1 from_file from_name=
    from_file=$(key_file_field 'key[[:space:]]*id')
    if [ -n "$p8" ]; then
        from_name=$(basename "$p8" .p8)
        from_name=${from_name#AuthKey_}
    fi
    if [ -n "$from_file" ] && [ -n "$from_name" ] && [ "$from_file" != "$from_name" ]; then
        echo "the Key Id in gtty_key_id.txt doesn't match ${p8##*/}: use the key that belongs to it" >&2
        return 1
    fi
    printf '%s' "${from_file:-$from_name}"
}

preflight() {
    # 1. The Developer ID identity in the keychain.
    if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
        echo "sign-macos: the signing identity \"$IDENTITY\" is not in your keychain." >&2
        if [ -f "$DIR/gtty.p12" ]; then
            echo "Import it with:" >&2
            echo "  security import \"$DIR/gtty.p12\"" >&2
        else
            echo "No $DIR/gtty.p12 either: copy gtty.p12 to $DIR (or set GTTY_SIGNING_DIR)." >&2
        fi
        exit 1
    fi

    # 2. The notarytool keychain profile.
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "sign-macos: the notarytool profile \"$PROFILE\" doesn't work (missing, or its key was revoked)." >&2
        local p8 missing=0
        p8=$(key_file_p8) || exit 1
        if [ -z "$p8" ]; then
            echo "Missing AuthKey_<KEYID>.p8: copy it to $DIR (or set GTTY_SIGNING_DIR)." >&2
            missing=1
        fi
        if [ ! -s "$DIR/gtty_key_id.txt" ]; then
            echo "Missing gtty_key_id.txt (Issuer Id / Key Id): copy it to $DIR (or set GTTY_SIGNING_DIR)." >&2
            missing=1
        fi
        if [ $missing = 0 ]; then
            local key_id issuer
            key_id=$(key_file_key_id "$p8") || exit 1
            issuer=$(key_file_issuer)
            [ -n "$issuer" ] || fail "no \"Issuer Id: …\" line in $DIR/gtty_key_id.txt"
            [ -n "$key_id" ] || fail "no Key Id: add a \"Key Id: …\" line to $DIR/gtty_key_id.txt"
            echo "Create it with:" >&2
            echo "  xcrun notarytool store-credentials $PROFILE --key \"$p8\" --key-id $key_id --issuer $issuer" >&2
        fi
        exit 1
    fi

    # 3. The certificate's expiry: a warning within 30 days.
    local pem end
    pem=$(security find-certificate -c "$IDENTITY" -p 2>/dev/null) || true
    if [ -n "$pem" ]; then
        end=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate | sed 's/^notAfter=//')
        if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend $((WARN_DAYS * 24 * 3600)) >/dev/null; then
            echo "sign-macos: warning: the certificate expires on $end (within $WARN_DAYS days). Renew it, then run scripts/set-github-secrets.sh again." >&2
        fi
    fi
    echo "sign-macos: signing is set up ($IDENTITY, notary profile $PROFILE)."
}

# CI: the certificate into a temporary keychain, the API key into a file;
# both are gone when the script ends.
ci_setup() {
    local v
    for v in MACOS_CERT_P12 MACOS_CERT_PASSWORD KEYCHAIN_PASSWORD APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_TEAM_ID; do
        [ -n "${!v:-}" ] || fail "CI: $v is not set"
    done
    TMP=$(mktemp -d)
    KC="$TMP/gtty-signing.keychain-db"
    trap 'security delete-keychain "$KC" 2>/dev/null || true; rm -rf "$TMP"' EXIT
    umask 077
    printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$TMP/cert.p12"
    printf '%s\n' "$APPLE_API_KEY_P8" > "$TMP/AuthKey_$APPLE_API_KEY_ID.p8"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
    security set-keychain-settings -lut 21600 "$KC"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
    security import "$TMP/cert.p12" -k "$KC" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KC" >/dev/null
    # Searched first, the user's keychains after it.
    local old
    old=$(security list-keychains -d user | tr -d '"')
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KC" $old
    # The Developer ID identity of the team.
    SIGN_ID=$(security find-identity -v -p codesigning "$KC" | sed -n "s/.*\"\(Developer ID Application: .*($APPLE_TEAM_ID)\)\".*/\1/p" | head -1)
    [ -n "$SIGN_ID" ] || fail "CI: no Developer ID Application identity for team $APPLE_TEAM_ID in MACOS_CERT_P12"
    export GTTY_SIGN_ID="$SIGN_ID"
    export GTTY_NOTARY_KEY="$TMP/AuthKey_$APPLE_API_KEY_ID.p8"
    export GTTY_NOTARY_KEY_ID="$APPLE_API_KEY_ID"
    export GTTY_NOTARY_ISSUER="$APPLE_API_ISSUER_ID"
}

[ "$(uname)" = Darwin ] || fail "signing needs macOS"

if [ -n "${MACOS_CERT_P12:-}" ]; then
    [ $CHECK_ONLY = 1 ] && { echo "sign-macos: CI variables set: no checks"; exit 0; }
    ci_setup
else
    preflight
    [ $CHECK_ONLY = 1 ] && exit 0
    export GTTY_SIGN_ID="$IDENTITY"
    export GTTY_NOTARY_PROFILE="$PROFILE"
fi

# Not exec: in CI the trap removes the keychain afterwards.
scripts/package.sh
