#!/usr/bin/env bash
# Checks that need no root and change nothing: run before every commit.
#   tests/check.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
ok()  { printf '  [PASS] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; fail=1; }

echo "1. Versions agree"
v=$(cat VERSION)
[[ "$(jq -r .version manifest.json)" == "$v" ]] && ok "manifest.json is $v" || bad "manifest.json is not $v"
grep -q "kitVersion: \"$v\"" VpnWidget.qml && ok "VpnWidget.qml is $v" || bad "VpnWidget.qml kitVersion is not $v"
grep -q "^## $v" CHANGELOG.md && ok "CHANGELOG has $v" || bad "CHANGELOG has no entry for $v"

echo "2. Shell syntax"
for f in install.sh uninstall.sh system/*.sh system/bin/* system/lib/*.sh system/dispatcher.d/* tests/*.sh; do
  if head -1 "$f" | grep -q python3; then
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null || bad "syntax: $f"
  else
    bash -n "$f" 2>/dev/null || bad "syntax: $f"
  fi
done
(( fail )) || ok "all scripts parse"

echo "3. Sudoers template"
tmp=$(mktemp); sed 's/@USER@/nobody/g' system/sudoers.d/99-vpnkit > "$tmp"
visudo -c -f "$tmp" >/dev/null 2>&1 && ok "valid" || bad "sudoers template does not validate"
rm -f "$tmp"

echo "4. Everything the installer installs is executable"
for f in install.sh uninstall.sh system/install-root.sh system/uninstall-root.sh system/bin/* system/dispatcher.d/*; do
  [[ -x "$f" ]] || bad "not executable: $f"
done
(( fail )) || ok "modes fine"

echo "5. Profile generator (dry run on the example config)"
work=$(mktemp -d); mkdir -p "$work/etc/providers"
cp system/vpnkit.settings "$work/etc/vpnkit.conf"
cp providers/proton.preset "$work/etc/providers/proton.conf"
sed "s|/usr/local/lib/vpnkit/common.sh|$PWD/system/lib/common.sh|" system/bin/vpnkit-import > "$work/import"
out=$(VPNKIT_ETC="$work/etc" bash "$work/import" examples/wireguard.example.conf --print 2>&1)
if grep -q '^id=proton-se-1$' <<<"$out"; then ok "named proton-se-1"
else bad "unexpected output from the generator:"; head -5 <<<"$out" | sed 's/^/         /'; fi
grep -q '^autoconnect=false$' <<<"$out"      && ok "never connects on its own" || bad "autoconnect is not false"
grep -q '^method=disabled$' <<<"$out"        && ok "IPv6 disabled on the link" || bad "IPv6 not disabled"
grep -q '^dns-priority=-50$' <<<"$out"       && ok "DNS exclusive to the tunnel" || bad "DNS priority missing"
grep -q '^private-key=\[hidden\]$' <<<"$out" && ok "--print hides the key" || bad "--print shows the key"
rm -rf "$work"

echo "6. No key material or personal data in the repo"
if git grep -nE '(PrivateKey *= *|private-key=)[A-Za-z0-9+/]{43}=' -- . ':!examples' ':!tests' >/dev/null 2>&1; then
  bad "a private key is committed"; else ok "no private keys"; fi
# Home directories other than the placeholders used in docs and the test VM.
if git grep -nIE '/home/[a-z][a-z0-9_-]*' -- . | grep -vE '/home/(you|tester)\b' | grep -q .; then
  bad "a real home directory path: $(git grep -nIE '/home/[a-z][a-z0-9_-]*' -- . | grep -vE '/home/(you|tester)\b' | cut -d: -f1,2 | tr '\n' ' ')"
else ok "no real home directory paths"; fi
# Your own list of things that must never be published (names, domains, IP
# addresses), one extended regex per line, in .private-patterns. That file is
# gitignored: the list itself is personal.
if [[ -s .private-patterns ]]; then
  hits=$(git grep -nIiE -f .private-patterns -- . | cut -d: -f1,2 | tr '\n' ' ')
  [[ -z "$hits" ]] && ok "nothing from .private-patterns in the tree" || bad "personal data: $hits"
  hist=$(git log --all -p --format='%an %ae %cn %ce %s%n%b' | grep -ciE -f .private-patterns || true)
  [[ "$hist" == "0" ]] && ok "nothing from .private-patterns in the history" || bad "personal data in git history ($hist lines): rewrite before publishing"
else
  echo "  [SKIP] no .private-patterns file (see CONTRIBUTING.md)"
fi
if git log --all --format='%ae%n%ce' | sort -u | grep -v 'noreply' | grep -q .; then
  bad "commit e-mail that is not a noreply address: $(git log --all --format='%ae%n%ce' | sort -u | grep -v noreply | tr '\n' ' ')"
else ok "commits use noreply addresses only"; fi

echo "7. QML"
QMLLINT=$(command -v qmllint || ls /usr/lib/qt6/bin/qmllint 2>/dev/null || true)
if [[ -n "$QMLLINT" ]]; then
  # The shell's qs.* modules only exist inside the running shell, so import
  # warnings are expected; a syntax error makes qmllint fail.
  "$QMLLINT" -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" VpnWidget.qml >/dev/null 2>&1 && ok "qmllint" \
    || { "$QMLLINT" VpnWidget.qml 2>&1 | grep -qiE "syntax|expected token" && bad "QML syntax error" || ok "qmllint (warnings only)"; }
else
  echo "  [SKIP] qmllint not installed"
fi

echo "8. Omarchy plugin manifest"
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate . >/dev/null 2>&1 && ok "omarchy plugin validate" || bad "omarchy plugin validate failed"
else
  echo "  [SKIP] omarchy not installed"
fi

echo
(( fail )) && { echo "FAILED"; exit 1; }
echo "All checks passed."
