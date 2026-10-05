#!/bin/bash
# zapret: обход DPI для Discord и YouTube. Ставится на Arch и Debian/Ubuntu;
# в Omarchy дополнительно появляется окошко управления по Super+Z.
# Запускать от обычного пользователя; пароль sudo спросит сам. Повторный запуск безопасен.
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
  echo "Ошибка: $*" >&2
  exit 1
}

((EUID != 0)) || die "запускайте без sudo, от своего пользователя"
command -v systemctl >/dev/null || die "нужен systemd"

# На Arch zapret берётся из AUR, на Debian/Ubuntu собирается из исходников:
# в их репозиториях его нет.
install_arch() {
  sudo pacman -S --needed --noconfirm nftables curl jq
  [[ -x /opt/zapret/nfq/nfqws ]] && return
  command -v yay >/dev/null || die "нужен yay, чтобы поставить zapret-git из AUR"
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
  # По этой метке uninstall.sh понимает, что /opt/zapret ставили мы, а не пакет.
  sudo touch /opt/zapret/.built-by-zapret-omarchy
  rm -rf "$src"
}

step "Зависимости и zapret"
if command -v pacman >/dev/null; then
  install_arch
elif command -v apt-get >/dev/null; then
  install_debian
else
  die "поддерживаются только Arch и Debian/Ubuntu"
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
sudo install -d /etc/polkit-1/rules.d
sed "s/@USER@/$USER/g" "$repo/system/49-zapret-toggle.rules" |
  sudo install -m644 /dev/stdin /etc/polkit-1/rules.d/49-zapret-toggle.rules
sudo systemctl daemon-reload

for f in /etc/zapret-toggle/strategies/*.args; do
  name=$(basename "$f" .args)
  sudo /usr/local/lib/zapret-toggle/run "$name" --dry-run >/dev/null 2>&1 ||
    echo "Предупреждение: nfqws не принимает стратегию $name"
done

# Правила polkit на JavaScript появились в версии 0.106; в более старых
# (Ubuntu 22.04, Debian 11) наше правило не действует.
polkit_version=$(pkaction --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)
if [[ -z $polkit_version ]] || awk -v v="$polkit_version" 'BEGIN { exit !(v < 0.106) }'; then
  echo "Предупреждение: polkit старый или не найден, включать и выключать придётся через sudo:"
  echo "  sudo systemctl start|stop zapret-toggle@<стратегия>"
fi

step "Скрипт zapret-toggle и логотип"
install -Dm755 "$repo/bin/zapret-toggle" "$HOME/.local/bin/zapret-toggle"
install -Dm644 "$repo/share/logo.txt" "$HOME/.local/share/zapret-toggle/logo.txt"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Каталога ~/.local/bin нет в PATH: перезайдите в систему или запускайте ~/.local/bin/zapret-toggle" ;;
esac

if command -v omarchy-shell >/dev/null; then
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
fi

step "Подбор рабочей стратегии"
"$HOME/.local/bin/zapret-toggle" test || true

if command -v omarchy-shell >/dev/null; then
  step "Готово. Super+Z открывает окошко."
  echo "Если окошко не появляется, перезапустите оболочку: omarchy restart shell"
else
  step "Готово. Управление из терминала: zapret-toggle help"
  echo "Окошко есть только в Omarchy. Автозапуск: добавьте в автозагрузку своей"
  echo "среды команду \"zapret-toggle autostart run\" и включите zapret-toggle autostart on."
fi
