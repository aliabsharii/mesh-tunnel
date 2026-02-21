#!/usr/bin/env bash
set -euo pipefail

# ========= DEFAULTS =========
DEFAULT_PORT="655"
DEFAULT_MTU="1380"
PING_INTERVAL="10"
PING_TIMEOUT="5"
DEFAULT_PRIV_PREFIX="10.20.0"     # /24
DEFAULT_PRIV_START="2"
DEFAULT_PRIV_END="254"

STATE_DIR="/etc/tinc/mesh_state"
mkdir -p "$STATE_DIR"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

need bash; need ip; need systemctl; need tincd; need ssh; need scp; need sed; need awk; need grep; need cut; need tr

HAS_SSHPASS=0
if command -v sshpass >/dev/null 2>&1; then HAS_SSHPASS=1; fi

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no)

usage(){
  cat <<USAGE
tinc-mesh.sh - minimal Tinc mesh manager (no web panel)

Usage:
  init   --net NET --name NAME --pub PUBIP --priv PRIVIP --mask NETMASK [--port PORT] [--mtu MTU]
  add    --net NET --name NAME --pub PUBIP --priv PRIVIP --ssh-user USER [--port PORT] [--mtu MTU]
  addq   --net NET --pub PUBIP [--ssh-user USER] [--name NAME] [--priv PRIVIP] [--port PORT] [--mtu MTU]
  del    --net NET --name NAME
  list   --net NET
  push   --net NET
  restart --net NET

Auth:
- Password prompt (recommended): add/addq will ask for SSH password (not stored, not shown).
- sshpass is used if installed. Install: apt-get install -y sshpass

Examples:
  ./tinc-mesh.sh init --net ali --name iranserver --pub 88.218.18.155 --priv 10.20.0.1 --mask 255.255.255.0
  ./tinc-mesh.sh addq --net ali --pub 91.107.154.234
  ./tinc-mesh.sh del --net ali --name ger6

USAGE
}

cmd="${1:-}"; shift || true

getarg(){
  local key="$1"; shift
  local val=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "$key") val="${2:-}"; echo "$val"; return 0 ;;
    esac
    shift
  done
  return 1
}

net_dir(){ echo "/etc/tinc/$1"; }
hosts_dir(){ echo "/etc/tinc/$1/hosts"; }
nodes_file(){ echo "$STATE_DIR/$1.nodes"; } # name|pub|priv|ssh_user|auth_type|auth_value|port|mtu
# auth_value is "-" by default (password not stored)

ensure_pkgs_local(){
  export DEBIAN_FRONTEND=noninteractive
  if ! dpkg -s tinc >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y tinc net-tools iproute2 >/dev/null
  fi
}

prompt_pass(){
  local prompt="${1:-SSH Password: }"
  local p
  read -r -s -p "$prompt" p
  printf '\n' >&2
  [[ -n "$p" ]] || die "Empty password."
  printf '%s' "$p"
}

remote_run_pass(){
  local user="$1" ipaddr="$2" pass="$3" script="$4"
  [[ $HAS_SSHPASS -eq 1 ]] || die "sshpass not installed. Install it: apt-get install -y sshpass"
  sshpass -p "$pass" ssh "${ssh_opts[@]}" "$user@$ipaddr" "bash -s" <<<"$script"
}
remote_scp_pass(){
  local pass="$1"; shift
  [[ $HAS_SSHPASS -eq 1 ]] || die "sshpass not installed. Install it: apt-get install -y sshpass"
  sshpass -p "$pass" scp "${ssh_opts[@]}" "$@"
}

write_tinc_conf(){
  local net="$1" name="$2"
  cat >"$(net_dir "$net")/tinc.conf" <<CONF
Name = $name
AddressFamily = ipv4
Interface = $net

# --- Performance & stability tuning ---
Mode = router
Compression = 0
Cipher = aes-128-gcm
Digest = sha256
DirectOnly = yes
AutoConnect = yes
PingInterval = $PING_INTERVAL
PingTimeout  = $PING_TIMEOUT
CONF
}

write_tinc_up(){
  local net="$1" priv="$2" mask="$3" mtu="$4"
  cat >"$(net_dir "$net")/tinc-up" <<UP
#!/bin/sh
/sbin/ifconfig \$INTERFACE $priv netmask $mask
/sbin/ip link set dev \$INTERFACE mtu $mtu || true
UP
  chmod +x "$(net_dir "$net")/tinc-up"
  cat >"$(net_dir "$net")/tinc-down" <<'DOWN'
#!/bin/sh
/sbin/ifconfig $INTERFACE down
DOWN
  chmod +x "$(net_dir "$net")/tinc-down"
}

write_host_file(){
  local net="$1" node="$2" pub="$3" priv="$4" port="$5"
  cat >"$(hosts_dir "$net")/$node" <<HOST
Address = $pub
Port = $port
Subnet = $priv/32
PMTUDiscovery = yes
ClampMSS = yes
HOST
}

set_mtu_now(){
  local net="$1" mtu="$2"
  local iface="tinc.$net"
  if ip link show "$iface" >/dev/null 2>&1; then
    ip link set dev "$iface" mtu "$mtu" || true
  fi
}

restart_tinc(){
  local net="$1" mtu="$2"
  systemctl enable "tinc@$net" >/dev/null 2>&1 || true
  systemctl restart "tinc@$net"
  set_mtu_now "$net" "$mtu"
}

reload_tinc_hup(){
  local net="$1"
  pkill -HUP -f "tincd -n $net" >/dev/null 2>&1 || true
}

save_node(){
  local net="$1" name="$2" pub="$3" priv="$4" ssh_user="$5" auth_type="$6" auth_val="$7" port="$8" mtu="$9"
  touch "$(nodes_file "$net")"
  grep -vE "^${name//\./\\.}\|" "$(nodes_file "$net")" >"$(nodes_file "$net").tmp" || true
  mv "$(nodes_file "$net").tmp" "$(nodes_file "$net")"
  echo "$name|$pub|$priv|$ssh_user|$auth_type|$auth_val|$port|$mtu" >>"$(nodes_file "$net")"
}

get_node_line(){
  local net="$1" name="$2"
  local f; f="$(nodes_file "$net")"
  [[ -f "$f" ]] || return 1
  grep -E "^${name//\./\\.}\|" "$f" | tail -n1
}

remove_node_state(){
  local net="$1" name="$2"
  local f; f="$(nodes_file "$net")"
  [[ -f "$f" ]] || return 0
  grep -vE "^${name//\./\\.}\|" "$f" >"${f}.tmp" || true
  mv "${f}.tmp" "$f"
}

list_nodes(){
  local net="$1"
  local f; f="$(nodes_file "$net")"
  [[ -f "$f" ]] || { echo "(no nodes saved yet)"; return 0; }
  echo "NAME | PUBLIC_IP | PRIVATE_IP | SSH_USER | AUTH | PORT | MTU"
  echo "-----|----------|-----------|---------|------|------|----"
  awk -F'|' '{printf "%s | %s | %s | %s | %s | %s | %s\n",$1,$2,$3,$4,$5,$7,$8}' "$f"
}

find_free_priv(){
  local net="$1"
  local used="|"
  local f; f="$(nodes_file "$net")"
  if [[ -f "$f" ]]; then
    while IFS='|' read -r n pub priv rest; do
      used="${used}${priv}|"
    done <"$f"
  fi
  for i in $(seq "$DEFAULT_PRIV_START" "$DEFAULT_PRIV_END"); do
    cand="${DEFAULT_PRIV_PREFIX}.${i}"
    if [[ "$used" != *"|${cand}|"* ]]; then
      echo "$cand"; return 0
    fi
  done
  die "No free private IP in ${DEFAULT_PRIV_PREFIX}.X"
}

sanitize_name(){
  echo "$1" | tr -cd 'a-zA-Z0-9_-'
}

get_main_name(){
  grep -E '^\s*Name\s*=' "$(net_dir "$1")/tinc.conf" | head -n1 | cut -d= -f2- | xargs
}

get_netmask(){
  grep -Eo 'netmask[[:space:]]+[0-9.]+' "$(net_dir "$1")/tinc-up" 2>/dev/null | awk '{print $2}' | head -n1 || true
}

push_hosts_to_all(){
  local net="$1"
  local f; f="$(nodes_file "$net")"
  [[ -f "$f" ]] || die "No nodes file: $f"
  local hdir; hdir="$(hosts_dir "$net")"
  [[ -d "$hdir" ]] || die "Missing hosts dir: $hdir"

  while IFS='|' read -r name pub priv ssh_user auth_type auth_val port mtu; do
    [[ "$auth_type" == "local" ]] && continue
    echo "-> Sync hosts to $name ($pub)"
    # password not stored: ask each time unless user exported MESH_SSH_PASS
    pass="${MESH_SSH_PASS:-}"
    if [[ -z "$pass" ]]; then
      pass="$(prompt_pass "SSH password for ${ssh_user}@${pub}: ")"
    fi
    remote_scp_pass "$pass" -r "$hdir"/* "${ssh_user}@${pub}:$hdir/" >/dev/null
    remote_run_pass "$ssh_user" "$pub" "$pass" "sudo pkill -HUP -f 'tincd -n $net' || true" >/dev/null
  done <"$f"

  reload_tinc_hup "$net"
  echo "OK: hosts synced + reloaded"
}

case "${cmd}" in
  init)
    net="$(getarg --net "$@" || true)"; name="$(getarg --name "$@" || true)"
    pub="$(getarg --pub "$@" || true)"; priv="$(getarg --priv "$@" || true)"
    mask="$(getarg --mask "$@" || true)"
    port="$(getarg --port "$@" || true)"; mtu="$(getarg --mtu "$@" || true)"
    [[ -n "$net" && -n "$name" && -n "$pub" && -n "$priv" && -n "$mask" ]] || { usage; exit 1; }
    port="${port:-$DEFAULT_PORT}"; mtu="${mtu:-$DEFAULT_MTU}"

    ensure_pkgs_local
    mkdir -p "$(hosts_dir "$net")"
    write_tinc_conf "$net" "$name"
    write_tinc_up "$net" "$priv" "$mask" "$mtu"
    write_host_file "$net" "$name" "$pub" "$priv" "$port"

    echo "-> Generating RSA keys (4096-bit) for $net ..."
    tincd -n "$net" -K4096 </dev/null >/dev/null 2>&1 || true

    restart_tinc "$net" "$mtu"
    save_node "$net" "$name" "$pub" "$priv" "root" "local" "-" "$port" "$mtu"

    echo "OK: Initialized main node $name in net $net"
    ;;

  addq)
    net="$(getarg --net "$@" || true)"
    pub="$(getarg --pub "$@" || true)"
    ssh_user="$(getarg --ssh-user "$@" || true)"; ssh_user="${ssh_user:-root}"
    name="$(getarg --name "$@" || true)"
    priv="$(getarg --priv "$@" || true)"
    port="$(getarg --port "$@" || true)"; mtu="$(getarg --mtu "$@" || true)"
    port="${port:-$DEFAULT_PORT}"; mtu="${mtu:-$DEFAULT_MTU}"

    [[ -n "$net" && -n "$pub" ]] || { usage; exit 1; }
    [[ -d "$(net_dir "$net")" ]] || die "Network not initialized locally. Run init first."

    pass="$(prompt_pass "SSH password for ${ssh_user}@${pub}: ")"

    if [[ -z "$name" ]]; then
      raw="$(remote_run_pass "$ssh_user" "$pub" "$pass" "hostname -s 2>/dev/null || hostname 2>/dev/null || echo node" | tail -n1)"
      name="$(sanitize_name "$raw")"
      [[ -n "$name" ]] || name="node$(date +%s)"
    else
      name="$(sanitize_name "$name")"
    fi

    if [[ -z "$priv" ]]; then
      priv="$(find_free_priv "$net")"
    fi

    # proceed
    "$0" add --net "$net" --name "$name" --pub "$pub" --priv "$priv" --ssh-user "$ssh_user" --port "$port" --mtu "$mtu" <<<"$pass"
    ;;

  add)
    net="$(getarg --net "$@" || true)"; name="$(getarg --name "$@" || true)"
    pub="$(getarg --pub "$@" || true)"; priv="$(getarg --priv "$@" || true)"
    ssh_user="$(getarg --ssh-user "$@" || true)"
    port="$(getarg --port "$@" || true)"; mtu="$(getarg --mtu "$@" || true)"
    [[ -n "$net" && -n "$name" && -n "$pub" && -n "$priv" && -n "$ssh_user" ]] || { usage; exit 1; }
    port="${port:-$DEFAULT_PORT}"; mtu="${mtu:-$DEFAULT_MTU}"

    [[ -d "$(net_dir "$net")" ]] || die "Network not initialized locally. Run init first."
    [[ -d "$(hosts_dir "$net")" ]] || die "Missing hosts dir locally."
    pass="$(prompt_pass "SSH password for ${ssh_user}@${pub}: ")"

    main_name="$(get_main_name "$net")"
    netmask="$(get_netmask "$net")"; [[ -n "$netmask" ]] || netmask="255.255.255.0"

    write_host_file "$net" "$name" "$pub" "$priv" "$port"

    remote_script=$(cat <<RS
set -e
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y tinc net-tools iproute2 >/dev/null

sudo rm -rf /etc/tinc/$net
sudo mkdir -p /etc/tinc/$net/hosts

sudo tee /etc/tinc/$net/tinc.conf >/dev/null <<CONF
Name = $name
AddressFamily = ipv4
Interface = $net
ConnectTo = $main_name

Mode = router
Compression = 0
Cipher = aes-128-gcm
Digest = sha256
DirectOnly = yes
AutoConnect = yes
PingInterval = $PING_INTERVAL
PingTimeout  = $PING_TIMEOUT
CONF

sudo tee /etc/tinc/$net/tinc-up >/dev/null <<UP
#!/bin/sh
/sbin/ifconfig \\$INTERFACE $priv netmask $netmask
/sbin/ip link set dev \\$INTERFACE mtu $mtu || true
UP
sudo chmod +x /etc/tinc/$net/tinc-up

sudo tee /etc/tinc/$net/tinc-down >/dev/null <<'DOWN'
#!/bin/sh
/sbin/ifconfig $INTERFACE down
DOWN
sudo chmod +x /etc/tinc/$net/tinc-down

sudo tee /etc/tinc/$net/hosts/$name >/dev/null <<HOST
Address = $pub
Port = $port
Subnet = $priv/32
PMTUDiscovery = yes
ClampMSS = yes
HOST

sudo tincd -n $net -K4096 </dev/null >/dev/null 2>&1 || true
sudo systemctl enable tinc@$net >/dev/null 2>&1 || true
sudo systemctl restart tinc@$net
RS
)

    remote_run_pass "$ssh_user" "$pub" "$pass" "$remote_script"

    hdir="$(hosts_dir "$net")"
    remote_scp_pass "$pass" "${ssh_user}@${pub}:/etc/tinc/$net/hosts/$name" "$hdir/" >/dev/null
    remote_scp_pass "$pass" "$hdir/$main_name" "${ssh_user}@${pub}:/etc/tinc/$net/hosts/" >/dev/null

    save_node "$net" "$name" "$pub" "$priv" "$ssh_user" "pass" "-" "$port" "$mtu"

    # you can export MESH_SSH_PASS=... if all nodes share same root password (optional)
    export MESH_SSH_PASS="${MESH_SSH_PASS:-$pass}"
    push_hosts_to_all "$net"

    restart_tinc "$net" "$mtu"
    echo "OK: Added node $name ($pub -> $priv) to net $net"
    ;;

  del)
    net="$(getarg --net "$@" || true)"
    name="$(getarg --name "$@" || true)"
    [[ -n "$net" && -n "$name" ]] || { usage; exit 1; }
    line="$(get_node_line "$net" "$name" || true)"
    [[ -n "$line" ]] || die "Node not found in state: $name"
    IFS='|' read -r n pub priv ssh_user auth_type auth_val port mtu <<<"$line"
    [[ "$auth_type" != "local" ]] || die "Refusing to delete local/main node."

    pass="${MESH_SSH_PASS:-}"
    [[ -n "$pass" ]] || pass="$(prompt_pass "SSH password for ${ssh_user}@${pub}: ")"

    echo "-> Removing $name (pub=$pub priv=$priv)"
    remote_run_pass "$ssh_user" "$pub" "$pass" "sudo systemctl stop tinc@${net} || true; sudo systemctl disable tinc@${net} || true; sudo rm -rf /etc/tinc/${net} || true" >/dev/null || true
    rm -f "$(hosts_dir "$net")/$name" || true

    # Remove host file from other nodes
    f="$(nodes_file "$net")"
    if [[ -f "$f" ]]; then
      while IFS='|' read -r oname opub opriv ossh oauthtype oauthval oport omtu; do
        [[ "$oname" == "$name" ]] && continue
        [[ "$oauthtype" == "local" ]] && continue
        p="${MESH_SSH_PASS:-}"
        [[ -n "$p" ]] || p="$(prompt_pass "SSH password for ${ossh}@${opub}: ")"
        remote_run_pass "$ossh" "$opub" "$p" "sudo rm -f /etc/tinc/${net}/hosts/${name} || true; sudo pkill -HUP -f 'tincd -n ${net}' || true" >/dev/null || true
      done <"$f"
    fi

    reload_tinc_hup "$net"
    remove_node_state "$net" "$name"
    echo "OK: Deleted node $name"
    ;;

  list)
    net="$(getarg --net "$@" || true)"
    [[ -n "$net" ]] || { usage; exit 1; }
    list_nodes "$net"
    ;;

  push)
    net="$(getarg --net "$@" || true)"
    [[ -n "$net" ]] || { usage; exit 1; }
    push_hosts_to_all "$net"
    ;;

  restart)
    net="$(getarg --net "$@" || true)"
    [[ -n "$net" ]] || { usage; exit 1; }
    mtu="$DEFAULT_MTU"
    if [[ -f "$(nodes_file "$net")" ]]; then
      mtu="$(awk -F'|' 'END{print $8}' "$(nodes_file "$net")" 2>/dev/null || echo "$DEFAULT_MTU")"
      [[ -n "$mtu" ]] || mtu="$DEFAULT_MTU"
    fi
    restart_tinc "$net" "$mtu"
    echo "OK: restarted tinc@$net"
    ;;

  ""|-h|--help|help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd"
    usage
    exit 1
    ;;
esac
