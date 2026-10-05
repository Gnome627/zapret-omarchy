#!/bin/bash
# zapret: DPI bypass for Discord and YouTube. Installs on Arch and Debian/Ubuntu;
# on Omarchy it also adds a control window on Super+Z.
# Run as a regular user; it asks for the sudo password itself. Safe to re-run.
set -euo pipefail

repo=$(dirname "$(readlink -f "$0")")
zapret_tag=v72.13
plugin_id=gnome627.zapret
plugin_dir=$HOME/.config/omarchy/plugins/$plugin_id
bindings=$HOME/.config/hypr/bindings.lua
autostart=$HOME/.config/hypr/autostart.lua
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

step() { echo -e "\n==> $*"; }
die() {
  echo "Error: $*" >&2
  exit 1
}

((EUID != 0)) || die "run it without sudo, as your own user"
command -v systemctl >/dev/null || die "systemd is required"

# On Arch zapret comes from the AUR; on Debian/Ubuntu it is built from source
# because their repositories do not carry it.
install_arch() {
  sudo pacman -S --needed --noconfirm nftables curl jq
  [[ -x /opt/zapret/nfq/nfqws ]] && return
  command -v yay >/dev/null || die "yay is required to install zapret-git from the AUR"
  yay -S --needed --noconfirm zapret-git
}

install_debian() {
  sudo apt-get update
  sudo apt-get install -y nftables curl jq git gawk libnotify-bin \
    build-essential libnetfilter-queue-dev libnfnetlink-dev libmnl-dev libcap-dev zlib1g-dev
  getent passwd zapret >/dev/null ||
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin zapret
  [[ -x /opt/zapret/nfq/nfqws ]] && return

  local src
  src=$(mktemp -d)
  git clone --depth 1 --branch "$zapret_tag" https://github.com/bol-van/zapret.git "$src"
  make -C "$src/nfq"
  sudo install -Dm755 "$src/nfq/nfqws" /opt/zapret/nfq/nfqws
  sudo install -d /opt/zapret/files/fake
  sudo install -m644 "$src"/files/fake/* /opt/zapret/files/fake/
  # This marker tells uninstall.sh that /opt/zapret was put there by us, not by a package.
  sudo touch /opt/zapret/.built-by-zapret-omarchy
  rm -rf "$src"
}

step "Dependencies and zapret"
if command -v pacman >/dev/null; then
  install_arch
elif command -v apt-get >/dev/null; then
  install_debian
else
  die "only Arch and Debian/Ubuntu are supported"
fi

step "System files: strategies, nftables rules, service, polkit rule"
sudo install -d /etc/zapret-toggle/strategies /usr/local/lib/zapret-toggle
sudo rm -f /etc/zapret-toggle/strategies/*.args
sudo install -m644 "$repo"/system/strategies/*.args /etc/zapret-toggle/strategies/
sudo install -m644 "$repo/system/rules.nft" /etc/zapret-toggle/rules.nft
# The hostlist may have been extended by hand, so an existing one is left alone.
[[ -e /etc/zapret-toggle/hosts.txt ]] || sudo install -m644 "$repo/system/hosts.txt" /etc/zapret-toggle/hosts.txt
sudo install -m755 "$repo/system/run" /usr/local/lib/zapret-toggle/run
sudo install -m644 "$repo/system/zapret-toggle@.service" /etc/systemd/system/zapret-toggle@.service
sudo install -d /etc/polkit-1/rules.d
sed "s/@USER@/$USER/g" "$repo/system/49-zapret-toggle.rules" |
  sudo install -m644 /dev/stdin /etc/polkit-1/rules.d/49-zapret-toggle.rules
sudo systemctl daemon-reload

for f in /etc/zapret-toggle/strategies/*.args; do
  name=$(basename "$f" .args)
  sudo /usr/local/lib/zapret-toggle/run "$name" --dry-run >/dev/null 2>&1 ||
    echo "Warning: nfqws rejects strategy $name"
done

# JavaScript polkit rules appeared in version 0.106; on older ones
# (Ubuntu 22.04, Debian 11) our rule has no effect.
polkit_version=$(pkaction --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)
if [[ -z $polkit_version ]] || awk -v v="$polkit_version" 'BEGIN { exit !(v < 0.106) }'; then
  echo "Warning: polkit is old or missing, so zapret-toggle will ask for the sudo password."
fi

step "zapret-toggle script and logo"
install -Dm755 "$repo/bin/zapret-toggle" "$HOME/.local/bin/zapret-toggle"
install -Dm644 "$repo/share/logo.txt" "$HOME/.local/share/zapret-toggle/logo.txt"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "~/.local/bin is not in PATH: log in again or run ~/.local/bin/zapret-toggle" ;;
esac

if command -v omarchy-shell >/dev/null; then
  step "Control window: Omarchy shell plugin"
  install -Dm644 "$repo/plugin/manifest.json" "$plugin_dir/manifest.json"
  install -Dm644 "$repo/plugin/Zapret.qml" "$plugin_dir/Zapret.qml"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$plugin_id"

  step "Super+Z, autostart and the Omarchy menu entry"
  if grep -q "zapret-toggle" "$bindings"; then
    echo "The binding is already there"
  else
    cat >>"$bindings" <<'LUA'

-- Zapret (DPI bypass for Discord and YouTube): control window.
o.bind("SUPER + Z", "Zapret", os.getenv("HOME") .. "/.local/bin/zapret-toggle menu")
LUA
  fi

  if ! grep -q "zapret-toggle" "$autostart"; then
    cat >>"$autostart" <<'LUA'

-- Zapret: starts on login if autostart is enabled in the window (Super+Z).
o.launch_on_start(os.getenv("HOME") .. "/.local/bin/zapret-toggle autostart run")
LUA
  fi
  hyprctl reload >/dev/null
  hyprctl configerrors

  if [[ -e $menu ]] && ! grep -q '"zapret"' "$menu"; then
    # The menu entry is described in Russian for ru locales, in English otherwise.
    case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in
      ru*) description="Обход блокировок Discord и YouTube" ;;
      *) description="Unblock Discord and YouTube" ;;
    esac
    # The row goes right before the closing brace of the file.
    row='  "zapret": {"icon":"󰒃","label":"Zapret","aliases":["zapret","dpi"],"description":"'$description'","action":"$HOME/.local/bin/zapret-toggle menu"},'
    last=$(grep -n '^}' "$menu" | tail -n1 | cut -d: -f1)
    sed -i "${last}i\\$row" "$menu"
  fi
fi

step "Picking a working strategy"
"$HOME/.local/bin/zapret-toggle" test || true

if command -v omarchy-shell >/dev/null; then
  step "Done. Super+Z opens the control window."
  echo "If the window does not appear, restart the shell: omarchy restart shell"
else
  step "Done. Control it from a terminal: zapret-toggle help"
  echo "The control window exists only on Omarchy. For autostart, add the command"
  echo "\"zapret-toggle autostart run\" to your session startup and run zapret-toggle autostart on."
fi
