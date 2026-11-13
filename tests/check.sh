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
for f in install.sh uninstall.sh system/*.sh system/bin/* system/lib/*.sh system/direct-bin/* system/dispatcher.d/* tests/*.sh; do
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
for f in install.sh uninstall.sh system/install-root.sh system/uninstall-root.sh system/bin/* system/direct-bin/* system/dispatcher.d/*; do
  [[ -x "$f" ]] || bad "not executable: $f"
done
(( fail )) || ok "modes fine"

echo "4b. Root-run scripts set a fixed PATH first (sudo may pass the caller's on)"
# Every command the sudoers file names, and every script those (or systemd,
# NetworkManager, setup) run as root.
ROOT_RUN=$(sed -nE 's#^@USER@ .*NOPASSWD: /usr/local/bin/([^ ]+).*#system/bin/\1#p' system/sudoers.d/99-vpnkit | sort -u)
ROOT_RUN+=$'\n'"system/bin/vpnkit-import system/bin/vpnkit-direct-rules system/bin/qbt-netns-up system/bin/qbt-netns-down"
ROOT_RUN+=$'\n'"system/bin/ff-netns-up system/bin/ff-netns-down"
ROOT_RUN+=$'\n'"system/dispatcher.d/50-vpnkit system/install-root.sh system/uninstall-root.sh"
for f in $ROOT_RUN; do
  first=$(awk '/^#/ || /^[[:space:]]*$/ || /^set -[euo]+( pipefail)?$/ {next} {print; exit}' "$f")
  [[ "$first" == 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"' ]] || bad "$f does not set PATH before its first command (first: $first)"
done
(( fail )) || ok "$(wc -w <<<"$ROOT_RUN") root-run scripts pin PATH"
# A command sudo runs directly must not look bash up in the caller's PATH:
# with "#!/usr/bin/env bash", env would do that before the script's own PATH.
SUDO_RUN=$(sed -nE 's#^@USER@ .*NOPASSWD: /usr/local/bin/([^ ]+).*#system/bin/\1#p' system/sudoers.d/99-vpnkit | sort -u)
for f in $SUDO_RUN; do
  [[ "$(head -1 "$f")" == '#!/usr/bin/bash' ]] || bad "$f: the shebang is not #!/usr/bin/bash (first line: $(head -1 "$f"))"
done
(( fail )) || ok "$(wc -w <<<"$SUDO_RUN") passwordless commands start with #!/usr/bin/bash"

echo "4c. Ownership: every command carries the kit's marker, and the uninstaller lists each"
mark=$(sed -nE 's/^VPNKIT_BIN_MARK="(.*)"$/\1/p' system/lib/owned.sh)
[[ -n "$mark" ]] || bad "no VPNKIT_BIN_MARK in system/lib/owned.sh"
for f in system/bin/*; do
  [[ "$(sed -n 2p "$f")" == "$mark" ]] || bad "$f: line 2 is not the marker"
  tr -s ' \\;\t' '\n' < system/uninstall-root.sh | grep -qxF "$(basename "$f")" || bad "uninstall-root.sh does not list $(basename "$f")"
done
(( fail )) || ok "$(ls system/bin | wc -l) commands marked and listed"

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

echo "5b. Launcher helpers never stop a script that runs under set -e"
# install.sh and vpn-direct run under set -euo pipefail, after the system part
# is done: a launcher cache that cannot be written, or an entry that cannot be
# read, must not end them there.
work=$(mktemp -d); mkdir -p "$work/bin" "$work/apps"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/update-desktop-database"; chmod 755 "$work/bin/update-desktop-database"
ln -s "$work/missing.desktop" "$work/apps/dangling.desktop"
printf '[Desktop Entry]\nExec=/usr/bin/true\n' > "$work/apps/locked.desktop"; chmod 000 "$work/apps/locked.desktop"
{ printf '[Desktop Entry]\nExec=\nExec=/opt/first --flag %%U\n'
  for i in $(seq 1 3000); do printf 'Exec=/opt/other-%s\n' "$i"; done; } > "$work/apps/many.desktop"
out=$(PATH="$work/bin:$PATH" bash -c 'set -euo pipefail; . "$1"
  vpnkit_desk_refresh "$2"; echo refresh-ok
  e=$(vpnkit_desk_exec "$2/dangling.desktop"); echo "dangling=[$e]"
  e=$(vpnkit_desk_exec "$2/locked.desktop"); [[ $EUID -eq 0 ]] && e=""; echo "locked=[$e]"
  e=$(vpnkit_desk_exec "$2/many.desktop"); echo "many=[$e]"
  echo end' _ system/lib/owned.sh "$work/apps" 2>&1)
is_out() { grep -qxF -- "$1" <<<"$out" && ok "$2" || bad "$2 (output: $(tr '\n' ' ' <<<"$out"))"; }
is_out "refresh-ok" "a launcher cache that cannot be updated is not an error"
is_out "dangling=[]" "an entry that is a dangling link has no Exec=, and is not an error"
is_out "locked=[]" "an entry that cannot be read has no Exec=, and is not an error"
is_out "many=[/opt/first]" "the first non-empty Exec= is the one, in an entry with thousands"
is_out "end" "the caller runs on"
chmod 600 "$work/apps/locked.desktop"; rm -rf "$work"

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
# Every command the panel waits for has a deadline: each Process is started
# through bounded() (timeout(1), process group) and has a Deadline backstop.
procs=$(grep -oE '^  Process \{$' VpnWidget.qml | wc -l)
unbounded=$(grep -nE '^[[:space:]]*[a-zA-Z]+Process\.command = ' VpnWidget.qml | grep -v 'bounded(' || true)
[[ -z "$unbounded" ]] && ok "every Process command goes through bounded()" || bad "Process command without a deadline: $unbounded"
deadlines=$(grep -cE '^  Deadline \{ process: [a-zA-Z]+Process;' VpnWidget.qml)
[[ "$deadlines" -eq "$procs" ]] && ok "every Process ($procs) has a Deadline backstop" || bad "$procs Process blocks but $deadlines Deadline backstops"

echo "8. Omarchy plugin manifest"
# The marketplace refuses a commit whose description is longer than 500 characters.
dlen=$(jq -r '.description | length' manifest.json)
(( dlen <= 500 )) && ok "manifest description is $dlen characters (marketplace limit 500)" \
  || bad "manifest description is $dlen characters; the marketplace limit is 500"
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate . >/dev/null 2>&1 && ok "omarchy plugin validate" || bad "omarchy plugin validate failed"
else
  echo "  [SKIP] omarchy not installed"
fi

echo
(( fail )) && { echo "FAILED"; exit 1; }
echo "All checks passed."
