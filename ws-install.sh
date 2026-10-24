#!/bin/bash
# ==============================================================
#   SSH over WebSocket (ports 80 / 443) - installer + user manager
#   Script by Coldplay
#   Supports: Debian / Ubuntu
# ==============================================================

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root:  sudo bash ws-install.sh${NC}"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}This installer supports Debian/Ubuntu only.${NC}"
    exit 1
fi

clear
echo -e "${CYAN}==============================================${NC}"
echo -e "${WHITE}      SSH over WebSocket  -  Installer${NC}"
echo -e "${RED}             Script by Coldplay${NC}"
echo -e "${CYAN}==============================================${NC}"
echo

# ---------- packages ----------
echo -e "${YELLOW}[1/9] Installing packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y openssh-server stunnel4 openssl curl python3 iproute2 iptables procps >/dev/null 2>&1 || {
    echo -e "${RED}Package installation failed.${NC}"
    exit 1
}
mkdir -p /etc/sshws

# ---------- ports ----------
echo -e "${YELLOW}[2/9] Choosing ports...${NC}"
# stop our own services first so a re-run doesn't see its own ports as busy
systemctl stop ws-proxy ws-tls 2>/dev/null

RESERVED=""
port_listening() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
port_busy() { [[ $1 == "$RESERVED" ]] || port_listening "$1"; }

ask_port() {   # ask_port <label> <default> <fallback>
    local label=$1 p=$2 fallback=$3 np
    while true; do
        if [[ ! $p =~ ^[0-9]+$ || $p -lt 1 || $p -gt 65535 ]]; then
            echo -e "${RED}'$p' is not a valid port.${NC}" >&2
        elif ! port_busy "$p"; then
            break
        else
            echo -e "${YELLOW}Port $p is already used by another service (nginx? the SSH-over-TLS script?).${NC}" >&2
        fi
        read -r -p "Enter another port for $label [$fallback]: " np </dev/tty
        p=${np:-$fallback}
    done
    echo "$p"
}

WS_PORT=$(ask_port "WebSocket (HTTP)" "${WS_PORT:-80}" 8880)
RESERVED=$WS_PORT
WSS_PORT=$(ask_port "WebSocket (TLS)" "${WSS_PORT:-443}" 8443)
echo "$WS_PORT" > /etc/sshws/ws_port
echo "$WSS_PORT" > /etc/sshws/wss_port
echo -e "  WebSocket : ${WHITE}${WS_PORT}${NC}    WebSocket TLS : ${WHITE}${WSS_PORT}${NC}"

# ---------- domain ----------
OLD_DOMAIN=$(cat /etc/sshws/domain 2>/dev/null)
DOMAIN=${WS_DOMAIN:-}
if [[ -z $DOMAIN ]]; then
    echo
    read -r -p "Enter your domain (e.g. vpn.example.com) [${OLD_DOMAIN:-none}]: " DOMAIN </dev/tty
    DOMAIN=${DOMAIN:-$OLD_DOMAIN}
fi
DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | tr -d ' ')
[[ $DOMAIN == "none" ]] && DOMAIN=""
if [[ -n $DOMAIN && ! $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo -e "${RED}'$DOMAIN' is not a valid domain. Continuing without a domain.${NC}"
    DOMAIN=""
fi
if [[ -n $DOMAIN ]]; then
    echo "$DOMAIN" > /etc/sshws/domain
    SERVER_IP=$(curl -s -m 5 ifconfig.me 2>/dev/null)
    DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z $DOMAIN_IP ]]; then
        echo -e "${YELLOW}Warning: ${DOMAIN} has no DNS record yet. Point it to this server's IP.${NC}"
    elif [[ -n $SERVER_IP && $DOMAIN_IP != "$SERVER_IP" ]]; then
        echo -e "${YELLOW}Warning: ${DOMAIN} points to ${DOMAIN_IP}, but this server is ${SERVER_IP}.${NC}"
    fi
else
    rm -f /etc/sshws/domain
fi

# ---------- certificate (used by the TLS port) ----------
echo -e "${YELLOW}[3/9] Preparing TLS certificate...${NC}"
PEM=/etc/sshws/ssh-ws.pem
CERT_TYPE="self-signed"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [[ -n $DOMAIN ]]; then
    # no Let's Encrypt certificate yet: try to get one (needs port 80 free)
    if [[ ! -f $LE_DIR/fullchain.pem ]]; then
        if port_listening 80; then
            echo -e "${YELLOW}Port 80 is busy, so a Let's Encrypt certificate can't be requested automatically.${NC}"
            echo -e "${YELLOW}Using a self-signed certificate. If you already have a certificate for ${DOMAIN}, re-run this installer and it will use it.${NC}"
        else
            echo -e "Requesting a Let's Encrypt certificate for ${WHITE}${DOMAIN}${NC}..."
            apt-get install -y certbot >/dev/null 2>&1
            # the hooks free port 80 during renewals, because the proxy may use it
            certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
                --register-unsafely-without-email \
                --pre-hook "systemctl stop ws-proxy || true" \
                --post-hook "systemctl start ws-proxy || true" >/tmp/certbot.log 2>&1 \
                || echo -e "${YELLOW}Let's Encrypt failed (see /tmp/certbot.log). Using a self-signed certificate.${NC}"
        fi
    fi

    # use the Let's Encrypt certificate if it exists now
    if [[ -f $LE_DIR/fullchain.pem ]]; then
        cat "$LE_DIR/privkey.pem" "$LE_DIR/fullchain.pem" > "$PEM"
        chmod 600 "$PEM"
        # rebuild the certificate automatically on every renewal
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/sshws.sh << HOOK
#!/bin/bash
[[ "\$RENEWED_LINEAGE" == */live/${DOMAIN} ]] || exit 0
cat "\$RENEWED_LINEAGE/privkey.pem" "\$RENEWED_LINEAGE/fullchain.pem" > ${PEM}
chmod 600 ${PEM}
systemctl restart ws-tls
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/sshws.sh
        CERT_TYPE="Let's Encrypt"
    fi
fi

# fallback: self-signed certificate (named after the domain when one was given)
if [[ $CERT_TYPE == "self-signed" ]]; then
    if [[ -n $DOMAIN || ! -f $PEM ]]; then
        CN=${DOMAIN:-$(hostname)}
        ADDEXT=()
        [[ -n $DOMAIN ]] && ADDEXT=(-addext "subjectAltName=DNS:${DOMAIN}")
        openssl req -new -x509 -days 3650 -nodes \
            -subj "/CN=${CN}" "${ADDEXT[@]}" \
            -keyout /tmp/sshws.key -out /tmp/sshws.crt >/dev/null 2>&1
        cat /tmp/sshws.key /tmp/sshws.crt > "$PEM"
        rm -f /tmp/sshws.key /tmp/sshws.crt
        chmod 600 "$PEM"
    fi
fi

# ---------- sshd ----------
echo -e "${YELLOW}[4/9] Configuring SSH...${NC}"
# make sure password login is on (also in drop-in files)
sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
# per-user connection limits need pam_limits
grep -q 'pam_limits.so' /etc/pam.d/sshd || echo 'session required pam_limits.so' >> /etc/pam.d/sshd
grep -q '^UsePAM' /etc/ssh/sshd_config || sed -i '1i UsePAM yes' /etc/ssh/sshd_config

touch /etc/sshws/users.db /etc/security/limits.d/sshws.conf

# ---------- speed tuning ----------
echo -e "${YELLOW}[5/9] Applying speed tuning (BBR, TCP buffers, SSH)...${NC}"
modprobe tcp_bbr 2>/dev/null
echo tcp_bbr > /etc/modules-load.d/bbr.conf
cat > /etc/sysctl.d/99-sshws.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle = 0
EOF
sysctl --system >/dev/null 2>&1
# SSH: no compression, no DNS lookups
sed -i '/^\s*Compression\s/d; /^\s*UseDNS\s/d' /etc/ssh/sshd_config
sed -i '1i Compression no\nUseDNS no' /etc/ssh/sshd_config
# drop dead connections within ~45 s so they stop counting against a user's limit
sed -i '/^\s*ClientAliveInterval\s/d; /^\s*ClientAliveCountMax\s/d' /etc/ssh/sshd_config
sed -i '1i ClientAliveInterval 15\nClientAliveCountMax 3' /etc/ssh/sshd_config
BBR_STATE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

# reload sshd with the new settings and find its port
if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
fi
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}

# ---------- udpgw ----------
UDPGW_PORT=${UDPGW_PORT:-7300}
echo -e "${YELLOW}[6/9] Installing udpgw on port ${UDPGW_PORT}...${NC}"
UDPGW_BIN=$(command -v badvpn-udpgw)

build_udpgw() {
    local d
    d=$(mktemp -d) || return 1
    apt-get install -y build-essential cmake wget >/dev/null 2>&1
    (
        cd "$d" || exit 1
        wget -q -O badvpn.tar.gz "https://github.com/ambrop72/badvpn/archive/1.999.130.tar.gz" || exit 1
        tar xzf badvpn.tar.gz || exit 1
        cd badvpn-1.999.130 || exit 1
        mkdir build && cd build || exit 1
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 || exit 1
        make -j"$(nproc)" >/dev/null 2>&1 || exit 1
        install -m 755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    )
    local rc=$?
    rm -rf "$d"
    return $rc
}

if [[ -z $UDPGW_BIN ]]; then
    apt-get install -y badvpn >/dev/null 2>&1
    UDPGW_BIN=$(command -v badvpn-udpgw)
fi
if [[ -z $UDPGW_BIN ]]; then
    echo -e "Building udpgw from source..."
    build_udpgw && UDPGW_BIN=/usr/local/bin/badvpn-udpgw
fi

if [[ -n $UDPGW_BIN && -x $UDPGW_BIN ]]; then
    # listens on localhost only: clients reach it through their SSH tunnel
    cat > /etc/systemd/system/udpgw.service << EOF
[Unit]
Description=BadVPN UDP gateway (udpgw)
After=network.target

[Service]
Type=simple
User=nobody
NoNewPrivileges=true
ExecStart=${UDPGW_BIN} --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients 1000 --max-connections-for-client 20 --loglevel warning
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable udpgw >/dev/null 2>&1
    systemctl restart udpgw
    echo "$UDPGW_PORT" > /etc/sshws/udpgw_port
else
    echo -e "${RED}Could not install udpgw. Everything else is installed.${NC}"
    rm -f /etc/sshws/udpgw_port
fi

# ---------- websocket proxy ----------
echo -e "${YELLOW}[7/9] Installing WebSocket proxy on ports ${WS_PORT} and ${WSS_PORT}...${NC}"
cat > /usr/local/bin/ws-proxy.py << 'PY_EOF'
#!/usr/bin/env python3
# SSH WebSocket proxy - Script by Coldplay
#
# Accepts a WebSocket-style HTTP upgrade request, answers "101 Switching
# Protocols", then relays the raw stream to the local SSH server.
#
# Anything the client sends between the HTTP request(s) and its SSH
# identification line (extra requests, padding, big payloads) is discarded,
# so sshd never sees it. A plain SSH client (no HTTP request) also works.

import asyncio
import os
import re

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("WS_PORT", "80"))
SSH_HOST = "127.0.0.1"
SSH_PORT = int(os.environ.get("SSH_PORT", "22"))

RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n\r\n"
)
HDR_END = re.compile(rb"\r?\n\r?\n")
BUFSIZE = 65536
HEADER_TIMEOUT = 10
MAX_HEADER = 262144      # 256 KB for the first request
MAX_JUNK = 4194304       # 4 MB discarded before the SSH banner
TAIL = 5                 # len(b"\nSSH-")


def close(writer):
    try:
        writer.close()
    except Exception:
        pass


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(BUFSIZE)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        close(writer)


def find_ssh(buf, line_start):
    """Index where the client's SSH identification line starts, or -1."""
    if line_start and buf.startswith(b"SSH-"):
        return 0
    i = buf.find(b"\nSSH-")
    return i + 1 if i >= 0 else -1


async def client_to_ssh(reader, writer, pending):
    """Forward client data to sshd, dropping everything before 'SSH-'."""
    buf = pending
    line_start = True
    synced = False
    discarded = 0
    try:
        while True:
            if not synced and buf:
                idx = find_ssh(buf, line_start)
                if idx >= 0:
                    discarded += idx
                    buf = buf[idx:]
                    synced = True
                elif len(buf) > TAIL:
                    # keep only a short tail, in case "SSH-" is split
                    discarded += len(buf) - TAIL
                    line_start = buf[-TAIL - 1:-TAIL] == b"\n"
                    buf = buf[-TAIL:]
                if discarded > MAX_JUNK:
                    return
            if synced and buf:
                writer.write(buf)
                await writer.drain()
                buf = b""
            data = await reader.read(BUFSIZE)
            if not data:
                break
            buf += data
    except Exception:
        pass
    finally:
        close(writer)


async def handle(client_reader, client_writer):
    remote_writer = None
    try:
        first = await asyncio.wait_for(client_reader.read(BUFSIZE), HEADER_TIMEOUT)
        if not first:
            return

        if first.startswith(b"SSH-"):
            # direct SSH client, no HTTP request in front
            pending = first
        else:
            buf = first
            while True:
                m = HDR_END.search(buf)
                if m:
                    break
                if len(buf) > MAX_HEADER:
                    return
                more = await asyncio.wait_for(client_reader.read(BUFSIZE), HEADER_TIMEOUT)
                if not more:
                    return
                buf += more
            pending = buf[m.end():]
            client_writer.write(RESPONSE)
            await client_writer.drain()

        remote_reader, remote_writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
        await asyncio.gather(
            client_to_ssh(client_reader, remote_writer, pending),
            pipe(remote_reader, client_writer),
        )
    except Exception:
        pass
    finally:
        close(client_writer)
        if remote_writer is not None:
            close(remote_writer)


def main():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    server = loop.run_until_complete(
        asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT, backlog=1024)
    )
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        loop.close()


if __name__ == "__main__":
    main()
PY_EOF
chmod 755 /usr/local/bin/ws-proxy.py

# TLS front: stunnel on the TLS port forwards to the plain WebSocket proxy
STUNNEL_BIN=$(command -v stunnel4 || command -v stunnel)
cat > /etc/sshws/stunnel.conf << EOF
foreground = yes
cert = ${PEM}
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ws-tls]
accept = ${WSS_PORT}
connect = 127.0.0.1:${WS_PORT}
EOF

cat > /etc/systemd/system/ws-proxy.service << EOF
[Unit]
Description=SSH WebSocket proxy
After=network.target

[Service]
Type=simple
User=nobody
Environment=WS_PORT=${WS_PORT}
Environment=SSH_PORT=${SSH_PORT}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ws-tls.service << EOF
[Unit]
Description=TLS front for the SSH WebSocket proxy (stunnel)
After=network.target ws-proxy.service

[Service]
Type=simple
ExecStart=${STUNNEL_BIN} /etc/sshws/stunnel.conf
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ws-proxy ws-tls >/dev/null 2>&1
systemctl restart ws-proxy
systemctl restart ws-tls

# open the ports if ufw is active
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${WS_PORT}/tcp" >/dev/null 2>&1
    ufw allow "${WSS_PORT}/tcp" >/dev/null 2>&1
fi

# ---------- speed-limit helper ----------
echo -e "${YELLOW}[8/9] Installing per-user limits (speed + connections)...${NC}"
cat > /usr/local/bin/ws-limit << 'LIMIT_EOF'
#!/bin/bash
# Per-user speed limits for SSH tunnels - Script by Coldplay
#
#   ws-limit apply    rebuild all limits from the user list
#   ws-limit clear    remove every limit
#   ws-limit status   show the active limits
#
# How it works: sockets that sshd opens for a user's tunnelled traffic are
# owned by that user's uid. iptables marks them (and their connections) and
# tc/htb shapes the marked traffic: uploads on the network interface,
# downloads on an IFB device that is fed from the interface's ingress.

DB=/etc/sshws/users.db
IFACE_FILE=/etc/sshws/iface
CHAIN=WSLIMIT
IFB=ifbws0
DEF=ffe0

detect_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

fw_clear() {
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while "$ipt" -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
        "$ipt" -t mangle -F "$CHAIN" 2>/dev/null
        "$ipt" -t mangle -X "$CHAIN" 2>/dev/null
    done
}

clear_all() {
    local dev
    fw_clear
    for dev in "$(cat "$IFACE_FILE" 2>/dev/null)" "$(detect_iface)"; do
        [[ -z $dev ]] && continue
        tc qdisc del dev "$dev" root 2>/dev/null
        tc qdisc del dev "$dev" ingress 2>/dev/null
    done
    ip link del "$IFB" 2>/dev/null
    rm -f "$IFACE_FILE"
}

# build_htb <device> <root-major>: one class per limited user, the rest unlimited
build_htb() {
    local dev=$1 maj=$2 i mark cls
    tc qdisc add dev "$dev" root handle "${maj}:" htb default "$DEF" || return 1
    tc class add dev "$dev" parent "${maj}:" classid "${maj}:1" htb rate 10gbit || return 1
    tc class add dev "$dev" parent "${maj}:1" classid "${maj}:${DEF}" htb \
        rate 10gbit ceil 10gbit burst 1m cburst 1m || return 1
    tc qdisc add dev "$dev" parent "${maj}:${DEF}" handle "${DEF}:" fq_codel 2>/dev/null
    for i in "${!names[@]}"; do
        mark=$((i + 1))
        cls=$(printf '%x' $((i + 16)))
        tc class add dev "$dev" parent "${maj}:1" classid "${maj}:${cls}" htb \
            rate "${rates[$i]}mbit" ceil "${rates[$i]}mbit" burst 64k cburst 64k || return 1
        tc qdisc add dev "$dev" parent "${maj}:${cls}" handle "${cls}:" fq_codel 2>/dev/null
        tc filter add dev "$dev" parent "${maj}:" protocol all prio 1 \
            handle "$mark" fw flowid "${maj}:${cls}" || return 1
    done
}

apply() {
    local c missing=""
    for c in tc ip iptables; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [[ -n $missing ]]; then
        echo "missing tools:$missing (install iproute2 and iptables)"
        return 1
    fi

    # users that have a speed limit
    local -a names=() uids=() rates=()
    local u exp m s uid
    if [[ -f $DB ]]; then
        while IFS='|' read -r u exp m s; do
            [[ -z $u || ! $s =~ ^[0-9]+$ ]] && continue
            s=$((10#$s))
            (( s > 0 )) || continue
            uid=$(id -u "$u" 2>/dev/null) || continue
            names+=("$u"); uids+=("$uid"); rates+=("$s")
        done < "$DB"
    fi

    clear_all
    (( ${#names[@]} == 0 )) && return 0

    local IF mod
    IF=$(detect_iface)
    if [[ -z $IF ]]; then
        echo "could not detect the network interface"
        return 1
    fi
    echo "$IF" > "$IFACE_FILE"

    for mod in sch_htb sch_fq_codel cls_fw xt_owner xt_MARK xt_CONNMARK act_connmark act_mirred; do
        modprobe "$mod" 2>/dev/null
    done
    modprobe ifb numifbs=0 2>/dev/null

    # mark everything each limited user's sshd sockets send
    local ipt i mark
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        "$ipt" -t mangle -N "$CHAIN" 2>/dev/null
        "$ipt" -t mangle -I OUTPUT 1 -j "$CHAIN" 2>/dev/null
        for i in "${!names[@]}"; do
            mark=$((i + 1))
            if ! "$ipt" -t mangle -A "$CHAIN" -m owner --uid-owner "${uids[$i]}" -j MARK --set-mark "$mark" 2>/dev/null \
               || ! "$ipt" -t mangle -A "$CHAIN" -m owner --uid-owner "${uids[$i]}" -j CONNMARK --save-mark 2>/dev/null; then
                if [[ $ipt == iptables ]]; then
                    echo "this kernel's iptables lacks the owner/MARK/CONNMARK modules"
                    clear_all
                    return 1
                fi
            fi
        done
    done

    # uploads: shape on the network interface
    if ! build_htb "$IF" 1; then
        echo "tc could not create the traffic classes on $IF (htb not available?)"
        clear_all
        return 1
    fi

    # downloads: mirror the interface's ingress to an IFB device and shape there
    if ip link add "$IFB" type ifb 2>/dev/null \
       && ip link set "$IFB" up \
       && build_htb "$IFB" 2 \
       && tc qdisc add dev "$IF" handle ffff: ingress \
       && tc filter add dev "$IF" parent ffff: protocol all prio 1 u32 match u32 0 0 \
              action connmark action mirred egress redirect dev "$IFB"; then
        return 0
    fi
    echo "warning: download limits are not available (kernel lacks ifb/act_connmark); only uploads are limited"
    tc qdisc del dev "$IF" ingress 2>/dev/null
    ip link del "$IFB" 2>/dev/null
    return 2
}

status() {
    local dev
    dev=$(cat "$IFACE_FILE" 2>/dev/null)
    if [[ -z $dev ]]; then
        echo "no speed limits are active"
        return 0
    fi
    echo "== upload side ($dev) =="
    tc -s class show dev "$dev" 2>/dev/null
    echo "== download side ($IFB) =="
    tc -s class show dev "$IFB" 2>/dev/null
}

case ${1:-apply} in
    apply)  apply ;;
    clear)  clear_all ;;
    status) status ;;
    *) echo "usage: ws-limit apply|clear|status"; exit 1 ;;
esac
LIMIT_EOF
chmod 755 /usr/local/bin/ws-limit

cat > /etc/systemd/system/ws-limit.service << EOF
[Unit]
Description=Per-user speed limits for SSH tunnels
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ws-limit apply
ExecStop=/usr/local/bin/ws-limit clear

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ws-limit >/dev/null 2>&1
/usr/local/bin/ws-limit apply >/dev/null 2>&1

cat > /usr/local/bin/ws-connlimit << 'CONN_EOF'
#!/bin/bash
# Enforce the per-user connection limit ("Max users") - Script by Coldplay
#
# sshd's own limit (pam_limits maxlogins) only counts interactive logins, so
# tunnel-only connections slip past it. This service counts the real SSH
# connections of every user in the user list and drops the NEWEST ones above
# that user's limit. The oldest connections are kept.
#
# usage: ws-connlimit [users.db]      (default /etc/sshws/users.db)

DB=${1:-/etc/sshws/users.db}
INTERVAL=2

enforce_once() {
    local out pid user lim
    # oldest connection first, so everything past the limit is the newest
    out=$(ps -eo user:32=,pid=,args= --sort=-etimes,pid 2>/dev/null | awk -v dbfile="$DB" '
        BEGIN {
            while ((getline line < dbfile) > 0) {
                split(line, f, "|")
                if (f[1] != "" && f[3] ~ /^[0-9]+$/ && f[3] + 0 > 0) limit[f[1]] = f[3] + 0
            }
            close(dbfile)
        }
        $3 ~ /^sshd(-session)?:$/ && ($1 in limit) {
            if (++seen[$1] > limit[$1]) print $2, $1, limit[$1]
        }')
    [[ -z $out ]] && return 0
    while read -r pid user lim; do
        kill -KILL "$pid" 2>/dev/null && echo "dropped an extra connection of '$user' (limit $lim)"
    done <<< "$out"
}

while true; do
    enforce_once
    sleep "$INTERVAL"
done
CONN_EOF
chmod 755 /usr/local/bin/ws-connlimit

cat > /etc/systemd/system/ws-connlimit.service << EOF
[Unit]
Description=Enforce per-user connection limits for SSH tunnels
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ws-connlimit /etc/sshws/users.db
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ws-connlimit >/dev/null 2>&1
systemctl restart ws-connlimit

# ---------- menu ----------
echo -e "${YELLOW}[9/9] Installing menu...${NC}"
cat > /usr/local/bin/wsmenu << 'MENU_EOF'
#!/bin/bash
# SSH over WebSocket user manager - Script by Coldplay

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

DB=/etc/sshws/users.db
LIMITS=/etc/security/limits.d/sshws.conf
BANNER=/etc/sshws/banner
WS_PORT=$(cat /etc/sshws/ws_port 2>/dev/null || echo 80)
WSS_PORT=$(cat /etc/sshws/wss_port 2>/dev/null || echo 443)
DOMAIN=$(cat /etc/sshws/domain 2>/dev/null)
UDPGW=$(cat /etc/sshws/udpgw_port 2>/dev/null)

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
fi
touch "$DB" "$LIMITS"

pause() { echo; read -r -p " Press Enter to continue..."; }

# usernames: 3-32 chars, letters (any case), digits, _ and -, must start with a letter or _
valid_username() {
    local LC_ALL=C
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_-]{2,31}$ ]]
}

reload_ssh() {
    sshd -t 2>/dev/null && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; }
}

count_online() { ps -u "$1" -o args= 2>/dev/null | grep -c '^sshd:'; }

apply_limits() {
    local out rc
    out=$(/usr/local/bin/ws-limit apply 2>&1)
    rc=$?
    if (( rc != 0 )); then
        echo -e " ${YELLOW}Speed limits are saved, but could not be fully enforced here:${NC}"
        echo -e " ${RED}${out}${NC}"
    fi
    return $rc
}

set_limit() {
    sed -i "/^$1[[:space:]]/d" "$LIMITS"
    echo "$1 hard maxlogins $2" >> "$LIMITS"
}

db_set() {   # db_set <user> <field-number> <value>
    awk -F'|' -v u="$1" -v f="$2" -v v="$3" 'BEGIN{OFS="|"} $1==u{$f=v} {print}' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
}

choose_user() {
    mapfile -t U < <(cut -d'|' -f1 "$DB" | grep .)
    if [[ ${#U[@]} -eq 0 ]]; then
        echo -e " ${RED}No users yet.${NC}"
        return 1
    fi
    local i=1 x
    for x in "${U[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $x"
        i=$((i + 1))
    done
    echo
    read -r -p " Select user number: " n
    if [[ ! $n =~ ^[0-9]+$ || $n -lt 1 || $n -gt ${#U[@]} ]]; then
        echo -e " ${RED}Invalid choice.${NC}"
        return 1
    fi
    SEL=${U[$((n - 1))]}
}

header() {
    clear
    local total=0 users u
    while IFS='|' read -r u _ _; do
        [[ -z $u ]] && continue
        total=$((total + $(count_online "$u")))
    done < "$DB"
    users=$(grep -c . "$DB")
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}        SSH over WebSocket - User Manager   ${CYAN}║${NC}"
    echo -e "${CYAN}║${RED}             Script by Coldplay             ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${NC} WS: ${GREEN}%-5s${NC} WSS: ${GREEN}%-5s${NC} Users: ${GREEN}%-3s${NC} Online: ${GREEN}%-3s${CYAN}║${NC}\n" "$WS_PORT" "$WSS_PORT" "$users" "$total"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo
}

add_user() {
    header
    echo -e " ${YELLOW}--- Add user ---${NC}"
    echo
    read -r -p " Username          : " u
    if ! valid_username "$u"; then
        echo -e " ${RED}Invalid username (3-32 chars: letters A-Z a-z, 0-9, _ -).${NC}"; pause; return
    fi
    if id "$u" &>/dev/null; then
        echo -e " ${RED}User already exists.${NC}"; pause; return
    fi
    IFS= read -r -s -p " Password          : " p; echo
    if [[ -z $p ]]; then
        echo -e " ${RED}Password cannot be empty.${NC}"; pause; return
    fi
    read -r -p " Days (expiry)    : " d
    if [[ ! $d =~ ^[0-9]+$ || $d -lt 1 ]]; then
        echo -e " ${RED}Days must be a number above 0.${NC}"; pause; return
    fi
    read -r -p " Max users        : " m
    if [[ ! $m =~ ^[0-9]+$ || $m -lt 1 ]]; then
        echo -e " ${RED}Max users must be a number above 0.${NC}"; pause; return
    fi
    read -r -p " Speed Mbps (0=off) : " s
    s=${s:-0}
    if [[ ! $s =~ ^[0-9]+$ ]]; then
        echo -e " ${RED}Speed must be a whole number (0 = unlimited).${NC}"; pause; return
    fi
    s=$((10#$s))

    local exp ip
    exp=$(date -d "+$d days" +%Y-%m-%d)
    if ! useradd -M -s /bin/false -e "$exp" "$u" 2>/dev/null \
       && ! useradd --badname -M -s /bin/false -e "$exp" "$u"; then
        echo -e " ${RED}Could not create user.${NC}"; pause; return
    fi
    printf '%s:%s\n' "$u" "$p" | chpasswd
    set_limit "$u" "$m"
    sed -i "/^$u|/d" "$DB"
    echo "$u|$exp|$m|$s" >> "$DB"
    (( s > 0 )) && apply_limits

    ip=$(curl -s -m 3 ifconfig.me 2>/dev/null)
    [[ -z $ip ]] && ip=$(hostname -I | awk '{print $1}')
    echo
    echo -e " ${GREEN}User created successfully${NC}"
    echo -e " ${CYAN}------------------------------${NC}"
    echo -e " Host      : ${WHITE}${DOMAIN:-$ip}${NC}"
    [[ -n $DOMAIN ]] && echo -e " Server IP : ${WHITE}$ip${NC}"
    echo -e " WS port   : ${WHITE}$WS_PORT${NC}"
    echo -e " WSS port  : ${WHITE}$WSS_PORT${NC}"
    [[ -n $UDPGW ]] && echo -e " UDPGW     : ${WHITE}127.0.0.1:$UDPGW${NC}"
    echo -e " Username  : ${WHITE}$u${NC}"
    printf ' Password  : %b%s%b\n' "$WHITE" "$p" "$NC"
    echo -e " Expires   : ${WHITE}$exp${NC}"
    echo -e " Max users : ${WHITE}$m${NC}"
    if (( s > 0 )); then
        echo -e " Speed     : ${WHITE}$s Mbps${NC}"
    else
        echo -e " Speed     : ${WHITE}unlimited${NC}"
    fi
    echo -e " ${CYAN}------------------------------${NC}"
    echo -e " Payload   :"
    echo -e " ${WHITE}GET / HTTP/1.1[crlf]Host: ${DOMAIN:-$ip}[crlf]Upgrade: websocket[crlf][crlf]${NC}"
    pause
}

delete_user() {
    header
    echo -e " ${YELLOW}--- Delete user ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " Delete '$SEL'? [y/N]: " c
    if [[ $c =~ ^[Yy]$ ]]; then
        local old_s
        old_s=$(awk -F'|' -v u="$SEL" '$1==u{print $4}' "$DB")
        pkill -KILL -u "$SEL" 2>/dev/null
        userdel "$SEL" 2>/dev/null
        sed -i "/^$SEL[[:space:]]/d" "$LIMITS"
        sed -i "/^$SEL|/d" "$DB"
        [[ $old_s =~ ^[0-9]+$ ]] && (( 10#$old_s > 0 )) && apply_limits
        echo -e " ${GREEN}User '$SEL' deleted.${NC}"
    else
        echo -e " Cancelled."
    fi
    pause
}

list_users() {
    header
    echo -e " ${YELLOW}--- All users ---${NC}"
    echo
    printf " ${WHITE}%-16s %-12s %-10s %-5s %-10s${NC}\n" "USERNAME" "EXPIRES" "DAYS LEFT" "MAX" "SPEED"
    echo -e " ${CYAN}----------------------------------------------------------${NC}"
    local u exp m s sp left col
    while IFS='|' read -r u exp m s; do
        [[ -z $u ]] && continue
        left=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
        col=$GREEN
        (( left <= 3 )) && col=$YELLOW
        (( left < 0 )) && { col=$RED; left="expired"; }
        sp="unlimited"
        [[ $s =~ ^[0-9]+$ ]] && (( 10#$s > 0 )) && sp="$((10#$s)) Mbps"
        printf " %-16s %-12s ${col}%-10s${NC} %-5s %-10s\n" "$u" "$exp" "$left" "$m" "$sp"
    done < "$DB"
    pause
}

online_users() {
    header
    echo -e " ${YELLOW}--- Online users ---${NC}"
    echo
    printf " ${WHITE}%-16s %-12s %-8s${NC}\n" "USERNAME" "CONNECTIONS" "LIMIT"
    echo -e " ${CYAN}-------------------------------------${NC}"
    local u m c any=0
    while IFS='|' read -r u _ m _; do
        [[ -z $u ]] && continue
        c=$(count_online "$u")
        if (( c > 0 )); then
            printf " %-16s ${GREEN}%-12s${NC} %-8s\n" "$u" "$c" "$m"
            any=1
        fi
    done < "$DB"
    (( any == 0 )) && echo -e " ${YELLOW}Nobody is online right now.${NC}"
    pause
}

change_expiry() {
    header
    echo -e " ${YELLOW}--- Change expiry ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New expiry in days from today: " d
    if [[ ! $d =~ ^[0-9]+$ || $d -lt 1 ]]; then
        echo -e " ${RED}Days must be a number above 0.${NC}"; pause; return
    fi
    local exp
    exp=$(date -d "+$d days" +%Y-%m-%d)
    usermod -e "$exp" "$SEL"
    db_set "$SEL" 2 "$exp"
    echo -e " ${GREEN}'$SEL' now expires on $exp.${NC}"
    pause
}

change_limit() {
    header
    echo -e " ${YELLOW}--- Change connection limit ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New max users (connections) for '$SEL': " m
    if [[ ! $m =~ ^[0-9]+$ || $m -lt 1 ]]; then
        echo -e " ${RED}Must be a number above 0.${NC}"; pause; return
    fi
    set_limit "$SEL" "$m"
    db_set "$SEL" 3 "$m"
    echo -e " ${GREEN}'$SEL' can now have $m connection(s) (enforced within a few seconds).${NC}"
    pause
}

change_speed() {
    header
    echo -e " ${YELLOW}--- Change speed limit ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New speed limit in Mbps for '$SEL' (0 = unlimited): " s
    if [[ ! $s =~ ^[0-9]+$ ]]; then
        echo -e " ${RED}Enter a whole number (0 = unlimited).${NC}"; pause; return
    fi
    s=$((10#$s))
    db_set "$SEL" 4 "$s"
    if apply_limits; then
        if (( s > 0 )); then
            echo -e " ${GREEN}'$SEL' is now limited to $s Mbps.${NC}"
        else
            echo -e " ${GREEN}'$SEL' is now unlimited.${NC}"
        fi
    fi
    pause
}

set_banner() {
    header
    echo -e " ${YELLOW}--- Login banner ---${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Set / change banner"
    echo -e "  ${GREEN}2)${NC} Remove banner"
    echo
    read -r -p " Select: " b
    case $b in
        1)
            echo -e " Type the banner text. Use ${WHITE}\\\\n${NC} for a new line."
            read -r -p " > " text
            if [[ -z $text ]]; then
                echo -e " ${RED}Banner cannot be empty.${NC}"; pause; return
            fi
            printf '%b\n' "$text" > "$BANNER"
            sed -i '/^\s*#\?\s*Banner\s/d' /etc/ssh/sshd_config
            sed -i "1i Banner $BANNER" /etc/ssh/sshd_config
            reload_ssh
            echo -e " ${GREEN}Banner saved.${NC}"
            ;;
        2)
            rm -f "$BANNER"
            sed -i '/^\s*Banner\s/d' /etc/ssh/sshd_config
            reload_ssh
            echo -e " ${GREEN}Banner removed.${NC}"
            ;;
        *) echo -e " ${RED}Invalid choice.${NC}" ;;
    esac
    pause
}

remove_expired() {
    header
    echo -e " ${YELLOW}--- Remove expired users ---${NC}"
    echo
    local today u exp m s n=0 limited=0
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r u exp m s; do
        [[ -z $u ]] && continue
        if [[ $exp < $today ]]; then
            pkill -KILL -u "$u" 2>/dev/null
            userdel "$u" 2>/dev/null
            sed -i "/^$u[[:space:]]/d" "$LIMITS"
            sed -i "/^$u|/d" "$DB"
            echo -e " Removed ${RED}$u${NC} (expired $exp)"
            [[ $s =~ ^[0-9]+$ ]] && (( 10#$s > 0 )) && limited=1
            n=$((n + 1))
        fi
    done < <(cat "$DB")
    echo
    (( limited )) && apply_limits
    echo -e " ${GREEN}$n expired user(s) removed.${NC}"
    pause
}

service_status() {
    header
    echo -e " ${YELLOW}--- Services ---${NC}"
    echo
    local s
    for s in ws-proxy ws-tls ssh udpgw ws-connlimit; do
        if systemctl is-active --quiet "$s" 2>/dev/null || { [[ $s == ssh ]] && systemctl is-active --quiet sshd 2>/dev/null; }; then
            echo -e " $s : ${GREEN}running${NC}"
        else
            echo -e " $s : ${RED}stopped${NC}"
        fi
    done
    local lim rules
    lim=$(awk -F'|' '$4+0>0{n++} END{print n+0}' "$DB")
    rules=$(iptables -t mangle -S WSLIMIT 2>/dev/null | grep -c 'MARK --set')
    if (( lim == 0 )); then
        echo -e " speed limits : ${YELLOW}none set${NC}"
    elif (( rules >= lim )); then
        echo -e " speed limits : ${GREEN}active for $lim user(s)${NC}"
    else
        echo -e " speed limits : ${RED}$lim user(s) set but NOT enforced${NC}"
    fi
    echo
    read -r -p " Restart ws-proxy, ws-tls and udpgw now? [y/N]: " c
    if [[ $c =~ ^[Yy]$ ]]; then
        systemctl restart ws-proxy && echo -e " ${GREEN}ws-proxy restarted.${NC}"
        systemctl restart ws-tls && echo -e " ${GREEN}ws-tls restarted.${NC}"
        systemctl restart udpgw 2>/dev/null && echo -e " ${GREEN}udpgw restarted.${NC}"
        systemctl restart ws-connlimit 2>/dev/null && echo -e " ${GREEN}ws-connlimit restarted.${NC}"
        apply_limits && echo -e " ${GREEN}speed limits re-applied.${NC}"
    fi
    pause
}

while true; do
    header
    echo -e "  ${GREEN}1)${NC} Add user"
    echo -e "  ${GREEN}2)${NC} Delete user"
    echo -e "  ${GREEN}3)${NC} List users"
    echo -e "  ${GREEN}4)${NC} Online users"
    echo -e "  ${GREEN}5)${NC} Change expiry"
    echo -e "  ${GREEN}6)${NC} Change connection limit"
    echo -e "  ${GREEN}7)${NC} Login banner"
    echo -e "  ${GREEN}8)${NC} Remove expired users"
    echo -e "  ${GREEN}9)${NC} Service status / restart"
    echo -e " ${GREEN}10)${NC} Change speed limit"
    echo -e "  ${RED}0)${NC} Exit"
    echo
    read -r -p " Select option: " opt
    case $opt in
        1) add_user ;;
        2) delete_user ;;
        3) list_users ;;
        4) online_users ;;
        5) change_expiry ;;
        6) change_limit ;;
        7) set_banner ;;
        8) remove_expired ;;
        9) service_status ;;
        10) change_speed ;;
        0) clear; exit 0 ;;
        *) echo -e " ${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
MENU_EOF
chmod +x /usr/local/bin/wsmenu

# "menu" shortcut, unless another script already owns that name
MENU_CMD=wsmenu
if [[ ! -e /usr/local/bin/menu ]]; then
    ln -s /usr/local/bin/wsmenu /usr/local/bin/menu
    MENU_CMD=menu
elif [[ $(readlink /usr/local/bin/menu) == /usr/local/bin/wsmenu ]]; then
    MENU_CMD=menu
fi

# ---------- done ----------
sleep 1
echo
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}  Installation complete${NC}"
echo -e "${GREEN}==============================================${NC}"
if systemctl is-active --quiet ws-proxy; then
    echo -e " WebSocket     : ${WHITE}port ${WS_PORT}${NC}"
else
    echo -e " WebSocket     : ${RED}not running (check: systemctl status ws-proxy)${NC}"
fi
if systemctl is-active --quiet ws-tls; then
    echo -e " WebSocket TLS : ${WHITE}port ${WSS_PORT}${NC}"
else
    echo -e " WebSocket TLS : ${RED}not running (check: systemctl status ws-tls)${NC}"
fi
[[ -n $DOMAIN ]] && echo -e " Domain        : ${WHITE}${DOMAIN}${NC}"
echo -e " Certificate   : ${WHITE}${CERT_TYPE}${NC}"
if systemctl is-active --quiet udpgw; then
    echo -e " UDPGW         : ${WHITE}127.0.0.1:${UDPGW_PORT}${NC} (reach it through the SSH tunnel)"
else
    echo -e " UDPGW         : ${RED}not running${NC}"
fi
echo -e " TCP control   : ${WHITE}${BBR_STATE:-unknown}${NC}"
echo -e " Conn. limits  : ${WHITE}enforced per user${NC}"
echo -e " Speed limits  : ${WHITE}per user (menu option 10)${NC}"
echo -e " Type ${WHITE}${MENU_CMD}${NC} to open the user manager"
echo -e "${RED}                         Script by Coldplay${NC}"
echo
