#!/bin/bash
# Убирает всё, что поставил install.sh. Пакет zapret-git остаётся: sudo pacman -Rns zapret-git
set -euo pipefail

plugin_id=gnome627.zapret
bindings=$HOME/.config/hypr/bindings.lua
autostart=$HOME/.config/hypr/autostart.lua
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

((EUID != 0)) || { echo "Ошибка: запускайте без sudo" >&2; exit 1; }

sudo systemctl stop 'zapret-toggle@*.service' || true
sudo rm -rf /etc/zapret-toggle /usr/local/lib/zapret-toggle
sudo rm -f /etc/systemd/system/zapret-toggle@.service /etc/polkit-1/rules.d/49-zapret-toggle.rules
sudo systemctl daemon-reload

omarchy plugin disable "$plugin_id" || true
rm -rf "$HOME/.config/omarchy/plugins/$plugin_id"
rm -rf "$HOME/.local/share/zapret-toggle" "$HOME/.config/zapret-toggle"
rm -f "$HOME/.local/bin/zapret-toggle"

# Удаляем строки привязки и автозапуска вместе с комментарием над ними.
sed -i '/^-- Zapret/d; /zapret-toggle/d' "$bindings" "$autostart"
[[ ! -e $menu ]] || sed -i '/^  "zapret": /d; /\/\/ Zapret: /d' "$menu"
hyprctl reload >/dev/null

echo "Удалено."
