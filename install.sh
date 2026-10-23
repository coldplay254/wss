#!/usr/bin/env bash
#=====================================================================
#  SSH over TLS  -  one-command installer + colourful user manager
#
#  Install:    sudo bash install.sh
#  Uninstall:  sudo bash install.sh uninstall
#  Optional env vars:  SSHTLS_PORT=443   SSHTLS_SNI=your.domain.com
#  Target OS:  Debian 10+ / Ubuntu 20.04+
#
#  After install, run:  sshtls   (or: menu)
#=====================================================================
set -e

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; N=$'\e[0m'
info(){ echo -e "${C}[*]${N} $*"; }
ok(){   echo -e "${G}[+]${N} $*"; }
die(){  echo -e "${R}[x]${N} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo)."

#---------------------------------------------------------------- uninstall
if [ "${1:-}" = "uninstall" ]; then
  info "Removing SSH over TLS ..."
  systemctl disable --now sshtls-stunnel sshtls-limiter 2>/dev/null || true
  rm -f /etc/systemd/system/sshtls-stunnel.service /etc/systemd/system/sshtls-limiter.service
  rm -f /usr/local/bin/sshtls-limiter /etc/ssh/sshd_config.d/99-sshtls.conf
  sed -i '/# BEGIN sshtls/,/# END sshtls/d' /etc/ssh/sshd_config 2>/dev/null || true
  [ "$(readlink /usr/local/bin/menu 2>/dev/null)" = "/usr/local/bin/sshtls" ] && rm -f /usr/local/bin/menu
  rm -f /usr/local/bin/sshtls
  rm -rf /etc/sshtls
  systemctl daemon-reload
  (systemctl reload ssh || systemctl reload sshd) 2>/dev/null || true
  ok "Removed. (Existing Linux user accounts were left in place.)"
  exit 0
fi

#---------------------------------------------------------------- pre-checks
command -v apt-get >/dev/null || die "This installer supports Debian/Ubuntu (apt) only."
PORT="${SSHTLS_PORT:-443}"
SNI="${SSHTLS_SNI:-$(hostname -f 2>/dev/null || hostname)}"

if ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . && ! systemctl is-active --quiet sshtls-stunnel 2>/dev/null; then
  echo
  ss -ltnp "sport = :$PORT" || true
  die "Port $PORT is already in use (see above). Stop that service, or install on another port: SSHTLS_PORT=8443 bash install.sh"
fi

#---------------------------------------------------------------- packages
info "Installing packages ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq openssh-server stunnel4 openssl procps curl >/dev/null
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}

#---------------------------------------------------------------- files / cert
mkdir -p /etc/sshtls
touch /etc/sshtls/limits /etc/sshtls/banner.txt
chmod 644 /etc/sshtls/banner.txt
cat > /etc/sshtls/sshtls.conf <<EOF
PORT=$PORT
SSH_PORT=$SSH_PORT
EOF

if [ ! -f /etc/sshtls/cert.pem ]; then
  info "Generating self-signed TLS certificate (CN=$SNI) ..."
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/sshtls/key.pem -out /etc/sshtls/cert.pem \
    -subj "/CN=$SNI" >/dev/null 2>&1
fi
chmod 600 /etc/sshtls/key.pem

#---------------------------------------------------------------- stunnel
info "Configuring stunnel (TLS :$PORT -> SSH :$SSH_PORT) ..."
{
  echo "foreground = yes"
  echo "pid ="
  if id stunnel4 >/dev/null 2>&1; then
    chown root:stunnel4 /etc/sshtls/key.pem; chmod 640 /etc/sshtls/key.pem
    printf 'setuid = stunnel4\nsetgid = stunnel4\n'
  fi
  cat <<EOF
cert = /etc/sshtls/cert.pem
key = /etc/sshtls/key.pem
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
TIMEOUTidle = 86400

[ssh-tls]
accept = $PORT
connect = 127.0.0.1:$SSH_PORT
EOF
} > /etc/sshtls/stunnel.conf

cat > /etc/systemd/system/sshtls-stunnel.service <<'EOF'
[Unit]
Description=SSH over TLS (stunnel)
After=network.target

[Service]
ExecStart=/usr/bin/stunnel /etc/sshtls/stunnel.conf
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

#---------------------------------------------------------------- sshd
info "Configuring OpenSSH for tunnel users ..."
groupadd -f sshtls
mkdir -p /etc/ssh/sshd_config.d
SSHD_BLOCK='Match Group sshtls
    PasswordAuthentication yes
    Banner /etc/sshtls/banner.txt
    AllowTcpForwarding yes
    X11Forwarding no
    AllowAgentForwarding no'
sed -i '/# BEGIN sshtls/,/# END sshtls/d' /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/99-sshtls.conf
if grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  printf '%s\n' "$SSHD_BLOCK" > /etc/ssh/sshd_config.d/99-sshtls.conf
else
  printf '\n# BEGIN sshtls\n%s\n# END sshtls\n' "$SSHD_BLOCK" >> /etc/ssh/sshd_config
fi
sshd -t || die "sshd config test failed - nothing was reloaded."
(systemctl reload ssh || systemctl reload sshd) 2>/dev/null || true

#---------------------------------------------------------------- limiter daemon
cat > /usr/local/bin/sshtls-limiter <<'LIMITER_EOF'
#!/usr/bin/env bash
# Enforces per-user connection limits and kills sessions of expired accounts.
DB=/etc/sshtls/limits
GROUP=sshtls
while true; do
  snap=$(ps -eo pid=,etimes=,args= | awk '$3 ~ /^sshd/ && $5=="[priv]" {print $4, $2, $1}')
  if [ -n "$snap" ]; then
    today=$(( $(date +%s) / 86400 ))
    for u in $(echo "$snap" | awk '{print $1}' | sort -u); do
      id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP" || continue
      mapfile -t pids < <(echo "$snap" | awk -v u="$u" '$1==u' | sort -k2 -rn | awk '{print $3}')
      # expired?  -> kill everything
      exp=$(getent shadow "$u" | cut -d: -f8)
      if [ -n "$exp" ] && [ "$exp" -ge 0 ] && [ "$today" -ge "$exp" ]; then
        keep=0
      else
        keep=$(grep "^$u=" "$DB" | tail -1 | cut -d= -f2)
        [ -z "$keep" ] && keep=1
        [ "$keep" -le 0 ] && continue
      fi
      for ((i=keep; i<${#pids[@]}; i++)); do
        pkill -KILL -P "${pids[$i]}" 2>/dev/null
        kill -KILL "${pids[$i]}" 2>/dev/null
      done
    done
  fi
  sleep 3
done
LIMITER_EOF
chmod +x /usr/local/bin/sshtls-limiter

cat > /etc/systemd/system/sshtls-limiter.service <<'EOF'
[Unit]
Description=SSH over TLS connection limiter
After=network.target

[Service]
ExecStart=/usr/local/bin/sshtls-limiter
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

#---------------------------------------------------------------- menu
cat > /usr/local/bin/sshtls <<'MENU_EOF'
#!/usr/bin/env bash
# SSH over TLS - user manager
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo sshtls"; exit 1; }
source /etc/sshtls/sshtls.conf
DB=/etc/sshtls/limits
GROUP=sshtls

R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'
M=$'\e[1;35m'; C=$'\e[1;36m'; W=$'\e[1;37m'; D=$'\e[2m'; N=$'\e[0m'

# useradd on Debian/Ubuntu rejects capital letters unless told otherwise
BADNAME=$(useradd --help 2>&1 | grep -o -- '--badnames\?' | head -1)

IP=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null)
[ -z "$IP" ] && IP=$(hostname -I | awk '{print $1}')

#------------------------------------------------------------ helpers
members(){ getent group "$GROUP" | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort; }
snap(){ ps -eo pid=,etimes=,args= | awk '$3 ~ /^sshd/ && $5=="[priv]" {print $4, $2, $1}'; }
pause(){ echo; read -rp "  ${D}Press Enter to continue...${N} " _; }
err(){ echo -e "  ${R}x $*${N}"; }
good(){ echo -e "  ${G}+ $*${N}"; }
get_limit(){ local l; l=$(grep "^$1=" "$DB" 2>/dev/null | tail -1 | cut -d= -f2); echo "${l:-1}"; }
set_limit(){ sed -i "/^$1=/d" "$DB"; echo "$1=$2" >> "$DB"; }
exp_field(){ getent shadow "$1" | cut -d: -f8; }
fmt_dur(){ local s=$1; printf "%dd %02dh %02dm" $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }
kill_sessions(){
  local u=$1 pid
  for pid in $(snap | awk -v u="$u" '$1==u{print $3}'); do
    pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
  done
  pkill -KILL -u "$u" 2>/dev/null
  return 0
}

banner(){
  clear
  local n o
  n=$(members | wc -l)
  o=$(snap | awk '{print $1}' | grep -Fxf <(members) | wc -l)
  echo -e "${C}╔════════════════════════════════════════════╗${N}"
  echo -e "${C}║${W}      SSH over TLS  •  User Manager         ${C}║${N}"
  echo -e "${C}╚════════════════════════════════════════════╝${N}"
  echo -e " ${D}Server${N} ${G}$IP${N}  ${D}Port${N} ${G}$PORT${N}  ${D}Users${N} ${Y}$n${N}  ${D}Online${N} ${M}$o${N}"
  echo
}

pick_user(){
  local arr c i=1
  mapfile -t arr < <(members)
  [ ${#arr[@]} -eq 0 ] && { err "No users yet."; return 1; }
  for u in "${arr[@]}"; do printf "   ${Y}%2d)${N} %s\n" "$i" "$u"; i=$((i+1)); done
  echo
  read -rp "  Select user (number or name): " c
  if [[ $c =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#arr[@]} ]; then SEL=${arr[$((c-1))]}; else SEL=$c; fi
  members | grep -qx "$SEL" || { err "Invalid user."; return 1; }
}

#------------------------------------------------------------ actions
add_user(){
  banner; echo -e "  ${W}ADD USER${N}\n"
  read -rp "  Username: " u
  [[ $u =~ ^[A-Za-z_][A-Za-z0-9_-]{2,30}$ ]] || { err "Invalid username (3-31 chars: letters, numbers, _ -)"; return; }
  id "$u" &>/dev/null && { err "That user already exists."; return; }
  while true; do
    read -rp "  Password: " p
    [ -n "$p" ] && break
    err "Password can't be empty."
  done
  while true; do
    read -rp "  How many days? (expiry, 0 = never): " d
    [[ $d =~ ^[0-9]+$ ]] && break
    err "Enter a number, e.g. 30."
  done
  while true; do
    read -rp "  Max number of users? (simultaneous logins, 0 = unlimited): " l
    [[ $l =~ ^[0-9]+$ ]] && break
    err "Enter a number, e.g. 2."
  done
  local args=(-M -s /bin/false -G "$GROUP")
  [ "$d" -gt 0 ] && args+=(-e "$(date -d "+$d days" +%F)")
  [ -n "$BADNAME" ] && args+=("$BADNAME")
  useradd "${args[@]}" "$u" || { err "useradd failed."; return; }
  printf '%s:%s\n' "$u" "$p" | chpasswd
  set_limit "$u" "$l"
  echo
  good "User created"
  echo -e "  ${D}────────────────────────────${N}"
  echo -e "  Host      : ${G}$IP${N}"
  echo -e "  TLS port  : ${G}$PORT${N}"
  echo -e "  Username  : ${G}$u${N}"
  echo -e "  Password  : ${G}$p${N}"
  if [ "$d" -gt 0 ]; then echo -e "  Expires   : ${Y}$(date -d "+$d days" +%F)${N}"; else echo -e "  Expires   : ${Y}never${N}"; fi
  echo -e "  Max conns : ${Y}$([ "$l" = 0 ] && echo unlimited || echo "$l")${N}"
  echo -e "  ${D}────────────────────────────${N}"
}

del_user(){
  banner; echo -e "  ${W}DELETE USER${N}\n"
  pick_user || return
  read -rp "  Really delete '$SEL'? (y/N): " a
  [[ $a =~ ^[Yy]$ ]] || { echo "  Cancelled."; return; }
  kill_sessions "$SEL"
  userdel -f "$SEL" 2>/dev/null
  sed -i "/^$SEL=/d" "$DB"
  good "Deleted $SEL"
}

set_expiry(){
  banner; echo -e "  ${W}SET EXPIRY${N}\n"
  pick_user || return
  echo
  read -rp "  Days from today, a date (YYYY-MM-DD), or 0 for never: " v
  if [ "$v" = "0" ]; then
    chage -E -1 "$SEL"; good "$SEL will never expire."
  elif [[ $v =~ ^[0-9]+$ ]]; then
    chage -E "$(date -d "+$v days" +%F)" "$SEL"; good "$SEL now expires on $(date -d "+$v days" +%F)."
  elif [[ $v =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$v" +%F &>/dev/null; then
    chage -E "$v" "$SEL"; good "$SEL now expires on $v."
  else
    err "Invalid input."
  fi
}

set_max(){
  banner; echo -e "  ${W}MAX CONNECTIONS PER USER${N}\n"
  pick_user || return
  echo -e "\n  Current limit for ${G}$SEL${N}: ${Y}$(get_limit "$SEL")${N}  ${D}(0 = unlimited)${N}"
  read -rp "  New limit: " l
  [[ $l =~ ^[0-9]+$ ]] || { err "Must be a number."; return; }
  set_limit "$SEL" "$l"
  good "Limit for $SEL set to $l. Extra connections are dropped within ~3 seconds."
}

change_pass(){
  banner; echo -e "  ${W}CHANGE PASSWORD${N}\n"
  pick_user || return
  read -rp "  New password (blank = random): " p
  [ -z "$p" ] && p=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
  printf '%s:%s\n' "$SEL" "$p" | chpasswd && good "New password for $SEL: ${G}$p${N}"
}

toggle_lock(){
  banner; echo -e "  ${W}LOCK / UNLOCK USER${N}\n"
  pick_user || return
  if [ "$(passwd -S "$SEL" | awk '{print $2}')" = "L" ]; then
    usermod -U "$SEL"; good "$SEL unlocked."
  else
    usermod -L "$SEL"; kill_sessions "$SEL"; good "$SEL locked and disconnected."
  fi
}

list_users(){
  banner; echo -e "  ${W}USER LIST${N}\n"
  local today=$(( $(date +%s) / 86400 )) u e ed left st stc lim
  printf "  ${B}%-16s %-12s %-6s %-6s %s${N}\n" USER EXPIRES LEFT LIMIT STATUS
  echo -e "  ${D}──────────────────────────────────────────────────${N}"
  if [ -z "$(members)" ]; then echo -e "  ${D}(no users)${N}"; return; fi
  for u in $(members); do
    e=$(exp_field "$u")
    st=ACTIVE
    if [ -z "$e" ] || [ "$e" -lt 0 ]; then
      ed="Never"; left="-"
    else
      ed=$(date -u -d "@$((e*86400))" +%F); left=$((e-today))
      [ "$left" -le 0 ] && { left=0; st=EXPIRED; }
    fi
    [ "$(passwd -S "$u" | awk '{print $2}')" = "L" ] && st=LOCKED
    case $st in ACTIVE) stc="${G}ACTIVE${N}";; EXPIRED) stc="${R}EXPIRED${N}";; *) stc="${Y}LOCKED${N}";; esac
    lim=$(get_limit "$u"); [ "$lim" = 0 ] && lim=unl
    printf "  %-16s %-12s %-6s %-6s %s\n" "$u" "$ed" "$left" "$lim" "$stc"
  done
}

online_users(){
  banner; echo -e "  ${W}ONLINE USERS${N}\n"
  local s total=0 u c m lim
  s=$(snap)
  printf "  ${B}%-16s %-8s %-8s %s${N}\n" USER CONNS LIMIT "CONNECTED FOR"
  echo -e "  ${D}──────────────────────────────────────────────────${N}"
  for u in $(members); do
    read -r c m < <(echo "$s" | awk -v u="$u" '$1==u{c++; if($2>m)m=$2} END{print c+0, m+0}')
    [ "$c" -gt 0 ] || continue
    lim=$(get_limit "$u"); [ "$lim" = 0 ] && lim=unl
    printf "  ${G}%-16s${N} %-8s %-8s %s\n" "$u" "$c" "$lim" "$(fmt_dur "$m")"
    total=$((total+c))
  done
  [ "$total" -eq 0 ] && echo -e "  ${D}Nobody is online right now.${N}"
  echo -e "\n  ${D}Total connections: $total${N}"
  echo -e "  ${D}(Client IPs aren't shown: TLS is terminated locally, so SSH sees 127.0.0.1.)${N}"
}

service_menu(){
  banner; echo -e "  ${W}SERVICES${N}\n"
  for s in sshtls-stunnel sshtls-limiter ssh sshd; do
    systemctl list-unit-files "$s.service" &>/dev/null || continue
    systemctl cat "$s" &>/dev/null || continue
    if systemctl is-active --quiet "$s"; then echo -e "  ${G}●${N} $s ${G}running${N}"; else echo -e "  ${R}●${N} $s ${R}stopped${N}"; fi
  done
  echo
  if ss -ltn "sport = :$PORT" | grep -q LISTEN; then echo -e "  Port ${G}$PORT${N} is listening."; else echo -e "  Port ${R}$PORT${N} is NOT listening."; fi
  echo
  read -rp "  Restart TLS + limiter services? (y/N): " a
  if [[ $a =~ ^[Yy]$ ]]; then systemctl restart sshtls-stunnel sshtls-limiter && good "Restarted."; fi
}

manage_banner(){
  banner; echo -e "  ${W}LOGIN BANNER${N}\n"
  local f=/etc/sshtls/banner.txt b line tmp
  if [ -s "$f" ]; then
    echo -e "  ${D}Current banner:${N}"
    sed 's/^/    /' "$f"
  else
    echo -e "  ${D}No banner set.${N}"
  fi
  echo
  echo -e "  ${Y}1)${N} Set / replace banner"
  echo -e "  ${Y}2)${N} Remove banner"
  echo -e "  ${Y}0)${N} Back"
  echo
  read -rp "  Choose: " b
  case $b in
    1)
      echo -e "\n  Type your banner text (multiple lines are fine)."
      echo -e "  Finish with a line containing only ${Y}.${N}\n"
      tmp=$(mktemp)
      while IFS= read -r line; do
        [ "$line" = "." ] && break
        printf '%s\n' "$line" >> "$tmp"
      done
      if [ -s "$tmp" ]; then
        install -m 644 "$tmp" "$f"
        good "Banner saved. Users see it on their next connection."
      else
        err "Banner was empty - nothing changed."
      fi
      rm -f "$tmp"
      ;;
    2) : > "$f"; good "Banner removed." ;;
    *) ;;
  esac
}

client_help(){
  banner; echo -e "  ${W}HOW TO CONNECT${N}\n"
  echo -e "  ${Y}Android / iOS tunnel apps${N} (HTTP Injector, HTTP Custom, NapsternetV...)"
  echo -e "    Mode: SSH + SSL/TLS   Host: ${G}$IP${N}   Port: ${G}$PORT${N}"
  echo -e "    Enter username/password. Set SNI to anything if the app asks."
  echo -e "    Certificate is self-signed, so disable certificate verification.\n"
  echo -e "  ${Y}Linux / macOS (SOCKS proxy on :1080)${N}"
  echo -e "    ${C}ssh -N -D 1080 -o ProxyCommand=\"openssl s_client -quiet -connect $IP:$PORT\" USER@$IP${N}\n"
  echo -e "  ${Y}Windows${N}: use stunnel client or an SSH+TLS capable app (e.g. NapsternetV)."
}

#------------------------------------------------------------ main loop
while true; do
  banner
  echo -e "  ${Y}1)${N} Add user"
  echo -e "  ${Y}2)${N} Delete user"
  echo -e "  ${Y}3)${N} Set expiry"
  echo -e "  ${Y}4)${N} Set max connections per user"
  echo -e "  ${Y}5)${N} Change password"
  echo -e "  ${Y}6)${N} Lock / unlock user"
  echo -e "  ${Y}7)${N} List users"
  echo -e "  ${Y}8)${N} Online users"
  echo -e "  ${Y}9)${N} Service status / restart"
  echo -e "  ${Y}10)${N} Login banner"
  echo -e "  ${Y}11)${N} How to connect"
  echo -e "  ${R}0)${N} Exit"
  echo
  read -rp "  Choose an option: " ch
  case $ch in
    1) add_user ;;
    2) del_user ;;
    3) set_expiry ;;
    4) set_max ;;
    5) change_pass ;;
    6) toggle_lock ;;
    7) list_users ;;
    8) online_users ;;
    9) service_menu ;;
    10) manage_banner ;;
    11) client_help ;;
    0|q|Q) clear; exit 0 ;;
    *) err "Invalid option." ;;
  esac
  pause
done
MENU_EOF
chmod +x /usr/local/bin/sshtls
command -v menu >/dev/null 2>&1 || ln -s /usr/local/bin/sshtls /usr/local/bin/menu

#---------------------------------------------------------------- firewall + start
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null && ok "ufw: allowed $PORT/tcp"
fi

systemctl daemon-reload
systemctl disable --now stunnel4 >/dev/null 2>&1 || true
systemctl enable --now sshtls-stunnel sshtls-limiter >/dev/null 2>&1
sleep 1

if systemctl is-active --quiet sshtls-stunnel; then
  ok "SSH over TLS is running on port $PORT"
else
  die "stunnel failed to start. Check: journalctl -u sshtls-stunnel -n 30"
fi

echo
echo -e "${G}============================================${N}"
echo -e "${G}  Install complete!${N}   Open the menu with:"
echo -e "      ${Y}sshtls${N}   ${C}(or: menu)${N}"
echo -e "${G}============================================${N}"
