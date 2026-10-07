#!/bin/bash
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Loads the macOS release secrets into the GitHub environment "release" of
# gttyterm/gitty (GTTY_GITHUB_REPO to use another), for CI's
# scripts/sign-macos.sh. Run it again after the yearly certificate
# renewal: every secret is replaced.
#
# Reads from $GTTY_SIGNING_DIR (default $HOME/tmp): gtty.p12,
# AuthKey_<KEYID>.p8 and gtty_key_id.txt ("Issuer Id: …" and "Key Id: …"
# lines). Asks for the
# .p12's password (hidden). Prints only the names of the secrets it sets.
# Needs gh (https://cli.github.com), logged in: gh auth login.
set -euo pipefail

REPO=${GTTY_GITHUB_REPO:-gttyterm/gitty}
ENV_NAME=release
TEAM_ID=N25UN9L94Q
DIR=${GTTY_SIGNING_DIR:-$HOME/tmp}

fail() {
    echo "set-github-secrets: $*" >&2
    exit 1
}

command -v gh >/dev/null || fail "gh is not installed (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in: run gh auth login"

# Reading the API key files in $DIR. gtty_key_id.txt looks like
#   Issuer Id: 69a6…
#   Key Id: 3N…
# (labels in any case; a file with only the Issuer ID still works).
# Messages go to stderr; values are never printed here. Same as in
# sign-macos.sh: keep the two in step.

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

# The three files.
missing=0
P8=$(key_file_p8) || exit 1
for name in gtty.p12 AuthKey_KEYID.p8 gtty_key_id.txt; do
    case $name in
        AuthKey_KEYID.p8) [ -n "$P8" ] && continue; name="AuthKey_<KEYID>.p8" ;;
        *) [ -s "$DIR/$name" ] && continue ;;
    esac
    echo "missing $name: copy it to $DIR (or set GTTY_SIGNING_DIR)" >&2
    missing=1
done
[ $missing = 0 ] || exit 1

KEY_ID=$(key_file_key_id "$P8") || exit 1
ISSUER=$(key_file_issuer)
[ -n "$ISSUER" ] || fail "no \"Issuer Id: …\" line in $DIR/gtty_key_id.txt"
[ -n "$KEY_ID" ] || fail "no Key Id: add a \"Key Id: …\" line to $DIR/gtty_key_id.txt"

# The .p12 password: hidden, only in this process's memory.
restore_tty() { stty echo 2>/dev/null || true; }
trap restore_tty EXIT INT TERM
read -rs -p "Password of gtty.p12: " CERT_PASSWORD
echo
[ -n "$CERT_PASSWORD" ] || fail "no password given"

# Wrong password? Try it on a throwaway keychain (macOS).
if command -v security >/dev/null; then
    TMP=$(mktemp -d)
    trap 'restore_tty; security delete-keychain "$TMP/check.keychain-db" 2>/dev/null || true; rm -rf "$TMP"' EXIT INT TERM
    KCPW=$(openssl rand -hex 16)
    security create-keychain -p "$KCPW" "$TMP/check.keychain-db" >/dev/null 2>&1
    security import "$DIR/gtty.p12" -k "$TMP/check.keychain-db" -P "$CERT_PASSWORD" >/dev/null 2>&1 ||
        fail "the password doesn't open gtty.p12"
fi

# The environment (no-op when it exists).
gh api --silent -X PUT "repos/$REPO/environments/$ENV_NAME" >/dev/null ||
    fail "can't create or reach the environment $ENV_NAME of $REPO"

# Values go through stdin, never the command line.
set_secret() {
    gh secret set "$1" --repo "$REPO" --env "$ENV_NAME" >/dev/null || fail "setting $1 failed"
    echo "set $1"
}
base64 < "$DIR/gtty.p12" | tr -d '\n' | set_secret MACOS_CERT_P12
printf '%s' "$CERT_PASSWORD" | set_secret MACOS_CERT_PASSWORD
set_secret APPLE_API_KEY_P8 < "$P8"
printf '%s' "$KEY_ID" | set_secret APPLE_API_KEY_ID
printf '%s' "$ISSUER" | set_secret APPLE_API_ISSUER_ID
printf '%s' "$TEAM_ID" | set_secret APPLE_TEAM_ID
openssl rand -base64 32 | tr -d '\n' | set_secret KEYCHAIN_PASSWORD
unset CERT_PASSWORD
echo "secrets of environment $ENV_NAME in $REPO are up to date"
