#!/bin/bash
# zapret для Omarchy: обход DPI для Discord и YouTube с окошком управления по Super+Z.
# Запускать от обычного пользователя; пароль sudo спросит сам. Повторный запуск безопасен.
set -euo pipefail

repo=$(dirname "$(readlink -f "$0")")
plugin_id=gnome627.zapret
plugin_dir=$HOME/.config/omarchy/plugins/$plugin_id
bindings=$HOME/.config/hypr/bindings.lua
autostart=$HOME/.config/hypr/autostart.lua
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

step() { echo -e "\n==> $*"; }
die() {
  echo "Ошибка: $*" >&2
  exit 1
}

((EUID != 0)) || die "запускайте без sudo, от своего пользователя"
command -v omarchy-shell >/dev/null || die "это не Omarchy: не найден omarchy-shell"

step "Зависимости"
sudo pacman -S --needed --noconfirm nftables curl jq
if [[ ! -x /opt/zapret/nfq/nfqws ]]; then
  yay -S --needed --noconfirm zapret-git
fi

step "Системные файлы: стратегии, правила nftables, сервис, правило polkit"
sudo install -d /etc/zapret-toggle/strategies /usr/local/lib/zapret-toggle
sudo rm -f /etc/zapret-toggle/strategies/*.args
sudo install -m644 "$repo"/system/strategies/*.args /etc/zapret-toggle/strategies/
sudo install -m644 "$repo/system/rules.nft" /etc/zapret-toggle/rules.nft
# Список доменов мог быть дополнен вручную, поэтому существующий не трогаем.
[[ -e /etc/zapret-toggle/hosts.txt ]] || sudo install -m644 "$repo/system/hosts.txt" /etc/zapret-toggle/hosts.txt
sudo install -m755 "$repo/system/run" /usr/local/lib/zapret-toggle/run
sudo install -m644 "$repo/system/zapret-toggle@.service" /etc/systemd/system/zapret-toggle@.service
sed "s/@USER@/$USER/g" "$repo/system/49-zapret-toggle.rules" |
  sudo install -m644 /dev/stdin /etc/polkit-1/rules.d/49-zapret-toggle.rules
sudo systemctl daemon-reload

for f in /etc/zapret-toggle/strategies/*.args; do
  name=$(basename "$f" .args)
  sudo /usr/local/lib/zapret-toggle/run "$name" --dry-run >/dev/null 2>&1 ||
    echo "Предупреждение: nfqws не принимает стратегию $name"
done

step "Скрипт zapret-toggle и логотип"
install -Dm755 "$repo/bin/zapret-toggle" "$HOME/.local/bin/zapret-toggle"
install -Dm644 "$repo/share/logo.txt" "$HOME/.local/share/zapret-toggle/logo.txt"

step "Окошко: плагин оболочки Omarchy"
install -Dm644 "$repo/plugin/manifest.json" "$plugin_dir/manifest.json"
install -Dm644 "$repo/plugin/Zapret.qml" "$plugin_dir/Zapret.qml"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy plugin enable "$plugin_id"

step "Super+Z, автозапуск и строка в меню Omarchy"
if grep -q "zapret-toggle" "$bindings"; then
  echo "Привязка уже есть"
else
  cat >>"$bindings" <<'LUA'

-- Zapret (обход DPI для Discord и YouTube): окошко управления.
o.bind("SUPER + Z", "Zapret", os.getenv("HOME") .. "/.local/bin/zapret-toggle menu")
LUA
fi

if ! grep -q "zapret-toggle" "$autostart"; then
  cat >>"$autostart" <<'LUA'

-- Zapret: включается при входе, если в окошке (Super+Z) включён автозапуск.
o.launch_on_start(os.getenv("HOME") .. "/.local/bin/zapret-toggle autostart run")
LUA
fi
hyprctl reload >/dev/null
hyprctl configerrors

if [[ -e $menu ]] && ! grep -q '"zapret"' "$menu"; then
  # Строка вставляется перед закрывающей скобкой файла.
  row='  "zapret": {"icon":"󰒃","label":"Zapret","aliases":["zapret","dpi"],"description":"Обход блокировок Discord и YouTube","action":"$HOME/.local/bin/zapret-toggle menu"},'
  last=$(grep -n '^}' "$menu" | tail -n1 | cut -d: -f1)
  sed -i "${last}i\\$row" "$menu"
fi

step "Подбор рабочей стратегии"
"$HOME/.local/bin/zapret-toggle" test || true

step "Готово. Super+Z открывает окошко."
echo "Если окошко не появляется, перезапустите оболочку: omarchy restart shell"
