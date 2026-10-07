#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the demo world the README animations are recorded in: a neutral
# home (zsh prompt "folder %"), and a small git project with a few
# branches. Everything lives under $GTTY_DEMO_ROOT (default
# /tmp/gtty-demo), which is wiped first. Used by make.sh.
set -eu
ROOT=${GTTY_DEMO_ROOT:-/tmp/gtty-demo}
rm -rf "$ROOT"
mkdir -p "$ROOT/home" "$ROOT/Downloads" "$ROOT/shop"

cat > "$ROOT/home/.zshrc" <<'RC'
PROMPT='%1~ %# '
unsetopt beep
alias ls='ls -G'
RC
: > "$ROOT/home/.zshenv"
printf 'PS1="\\W $ "\n' > "$ROOT/home/.bashrc"

cd "$ROOT/shop"
mkdir -p src docs assets
cat > README.md <<'T'
# shop

A small web shop: catalog, cart and checkout.
T
cat > notes.md <<'T'
- cart: keep items for 30 days
- checkout: retry the payment call once
T
cat > src/cart.py <<'T'
def total(items):
    return sum(i.price * i.qty for i in items)
T
cat > src/checkout.py <<'T'
from cart import total

def pay(order):
    return total(order.items)
T
cat > src/catalog.py <<'T'
PRODUCTS = ["mug", "shirt", "poster"]
T
cat > docs/setup.md <<'T'
Run `make dev`, then open http://localhost:8000.
T
printf 'sku,name,price\n1,mug,9\n2,shirt,19\n3,poster,12\n' > assets/products.csv
printf 'all:\n\t@echo build ok\n' > Makefile

g() { git -c user.name=demo -c user.email=demo@example.com -c init.defaultBranch=main "$@"; }
g init -q
g add -A
g commit -qm "first version"
for m in "catalog: three products" "cart: total with quantities" \
    "checkout: pay the cart total" "docs: how to run it" \
    "cart: keep items for 30 days" "checkout: retry the payment once" \
    "catalog: prices from the csv"; do
    echo "$m" >> CHANGES
    g add CHANGES
    g commit -qm "$m"
done
g branch feature/search
g branch fix/login-timeout
g branch release/1.2

# Things to drop on gtty from "another app".
printf 'invoice 2026-10\n' > "$ROOT/Downloads/invoice.pdf"
printf 'logo\n' > "$ROOT/Downloads/logo.png"
