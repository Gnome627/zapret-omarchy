#!/bin/bash
# Removes everything install.sh put in place. On Arch the zapret-git package
# stays: remove it with sudo pacman -Rns zapret-git
set -euo pipefail

plugin_id=gnome627.zapret
bindings=$HOME/.config/hypr/bindings.lua
autostart=$HOME/.config/hypr/autostart.lua
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

((EUID != 0)) || { echo "Error: run it without sudo" >&2; exit 1; }

sudo systemctl stop 'zapret-toggle@*.service' || true
sudo rm -rf /etc/zapret-toggle /usr/local/lib/zapret-toggle
sudo rm -f /etc/systemd/system/zapret-toggle@.service /etc/polkit-1/rules.d/49-zapret-toggle.rules
sudo systemctl daemon-reload

# A zapret that install.sh built from source (Debian/Ubuntu) goes away together
# with its user. One installed from a package is left alone.
if [[ -e /opt/zapret/.built-by-zapret-omarchy ]]; then
  sudo rm -rf /opt/zapret
  sudo userdel zapret 2>/dev/null || true
fi

rm -rf "$HOME/.local/share/zapret-toggle" "$HOME/.config/zapret-toggle"
rm -f "$HOME/.local/bin/zapret-toggle"

if command -v omarchy-shell >/dev/null; then
  omarchy plugin disable "$plugin_id" || true
  rm -rf "$HOME/.config/omarchy/plugins/$plugin_id"
  # Drop the binding and autostart lines together with the comment above them.
  sed -i '/^-- Zapret/d; /zapret-toggle/d' "$bindings" "$autostart"
  [[ ! -e $menu ]] || sed -i '/^  "zapret": /d; /\/\/ Zapret: /d' "$menu"
  hyprctl reload >/dev/null
fi

echo "Removed."
