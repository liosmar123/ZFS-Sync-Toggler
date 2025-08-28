#!/usr/bin/env bash
# zfs-sync-toggler.sh (v1.3)
# Clean TUI to toggle ZFS 'sync' with aligned columns and stable colors.
# Default: ASCII icons (no emoji) to avoid misalignment across terminals.
# Flags: --emoji --color --no-color --no-emoji --plain

set -euo pipefail

# ---------- Flags ----------
USE_COLOR=0
USE_EMOJI=0
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  # habilita color si hay TTY; el usuario puede forzarlo con --color
  USE_COLOR=1
fi

for arg in "${@:-}"; do
  case "$arg" in
    --emoji)    USE_EMOJI=1;;
    --no-emoji) USE_EMOJI=0;;
    --color)    USE_COLOR=1;;
    --no-color) USE_COLOR=0;;
    --plain)    USE_COLOR=0; USE_EMOJI=0;;
  esac
done

# ---------- Styles ----------
if [[ $USE_COLOR -eq 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""
fi

# ---------- Icons (ASCII first; emoji optional) ----------
if [[ $USE_EMOJI -eq 1 ]]; then
  I_APP="🛠"; I_ENV="🧭"; I_WARN="⚠️"; I_ERR="❌"; I_OK="✅"; I_EXIT="🚪"
  I_DISABLE="🚫"; I_REVERT="↩️"; I_INFO="ℹ️"; I_SUGG="🧭"; I_POOL="🫧"; I_DS="🧩"
else
  I_APP="ZFS"; I_ENV="ENV"; I_WARN="!"; I_ERR="x"; I_OK="✔"; I_EXIT="X"
  I_DISABLE="-"; I_REVERT="<"; I_INFO="i"; I_SUGG="?"; I_POOL="POOL"; I_DS="DS"
fi

LOG_FILE="/var/log/zfs-sync-toggle.log"
DRY_RUN=0

# ---------- Utils ----------
hr(){
  local cols=70
  if command -v tput >/dev/null 2>&1; then cols=$(tput cols || echo 70); fi
  printf " %s\n" "$(printf '─%.0s' $(seq 1 $(( cols>70?70:cols-2 ))))"
}
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
run(){ if [[ $DRY_RUN -eq 1 ]]; then printf "%sDRY-RUN:%s %s\n" "$DIM" "$RESET" "$*"; else eval "$@"; fi; }

require_cmds(){ for c in zpool zfs awk sed grep; do command -v "$c" >/dev/null 2>&1 || { echo " ${RED}${I_ERR}${RESET} Missing: $c"; exit 1; }; done; }

header(){
  clear 2>/dev/null || true
  printf " %s%s %s Sync Toggler%s  %s(interactive)%s\n" "$BOLD" "$I_APP" "ZFS" "$RESET" "$DIM" "$RESET"
  printf " %sLog:%s %s\n" "$DIM" "$RESET" "$LOG_FILE"
  hr
}

detect_env(){
  if grep -Eiqs 'truenas' /etc/*release 2>/dev/null || [[ -e /etc/truenas-install ]]; then
    echo "TrueNAS Community (Linux)"
    return
  fi
  if [[ -f /etc/os-release ]]; then . /etc/os-release; case "${ID,,}" in proxmox) echo "Proxmox";; *) echo "Linux";; esac; return; fi
  if uname -s | grep -qi freebsd; then echo "TrueNAS CORE"; return; fi
  echo "Unknown"
}

list_pools(){ zpool list -H -o name 2>/dev/null | awk 'NF'; }
list_datasets(){ zfs list -H -o name -t filesystem,volume 2>/dev/null | awk 'NF'; }
get_sync_value(){ zfs get -H -o value sync "$1" 2>/dev/null || echo "unknown"; }

status_mark(){
  local v="$1"
  if [[ "$v" == "disabled" ]]; then
    [[ $USE_COLOR -eq 1 ]] && printf "%s%s%s" "$GREEN" "$I_OK" "$RESET" || printf "%s" "$I_OK"
  else
    [[ $USE_COLOR -eq 1 ]] && printf "%s%s%s" "$RED" "$I_ERR" "$RESET" || printf "%s" "$I_ERR"
  fi
}

confirm(){ local p="$1"; read -r -p "$(printf "  %s %s [y/N]: " "$I_WARN" "$p")" a; [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; }

apply_sync(){ local val="$1" tgt="$2"; log "set sync=$val on $tgt"; run "zfs set sync=$val '$tgt'"; }

# ---------- Menus ----------
show_info(){
  echo
  printf " %s %s Pools (root dataset sync status)%s\n" "$BOLD" "$I_POOL" "$RESET"; hr
  local i=1
  while read -r p; do
    [[ -z "$p" ]] && continue
    local v; v="$(get_sync_value "$p")"
    printf "  %2d)  %-2s  %-20s  %s(sync=%s)%s\n" "$i" "$(status_mark "$v")" "$p" "$DIM" "$v" "$RESET"
    ((i++))
  done < <(list_pools)
  echo
  printf " %s %s Datasets (first 40)%s\n" "$BOLD" "$I_DS" "$RESET"; hr
  list_datasets | head -n 40 | sed 's/^/   · /'
  echo
}

show_suggestions(){
  local env="$1"; echo; printf " %s %s Environment suggestions %s[%s]%s\n" "$BOLD" "$I_ENV" "$DIM" "$env" "$RESET"; hr
  case "$env" in
    Proxmox)
      if [[ -f /etc/pve/storage.cfg ]]; then
        awk '$1=="zfspool"{in=1;next} in && /^pool:/{print "   · "$2} NF==0{in=0}' /etc/pve/storage.cfg | sort -u || true
      else echo "   · No zfspool storages found."; fi;;
    "TrueNAS Community (Linux)")
      list_datasets | grep -Ei 'vm|kvm|iscsi|smb|nfs|virt' | sed 's/^/   · /' || echo "   · (no obvious targets)";;
    *) echo "   · Review datasets hosting VMs/SMB/NFS/iSCSI.";;
  esac
  echo
}

bulk_apply(){
  local action="$1" val="disabled"; [[ "$action" == "revert" ]] && val="standard"
  echo; printf " %s %s Scope selection%s\n" "$BOLD" "$I_INFO" "$RESET"; hr
  printf "   1)  %-10s  %s\n" "By pool" "inherits to children"
  printf "   2)  %-10s  %s\n" "Specific DS" "regex (grep -E) supported"
  echo; read -r -p "  Select [1-2]: " s; echo

  if [[ "$s" == "1" ]]; then
    mapfile -t pools < <(list_pools); [[ ${#pools[@]} -eq 0 ]] && { echo " ${I_ERR} No pools found."; return; }
    printf " %s %s Detected pools%s\n" "$BOLD" "$I_POOL" "$RESET"; hr
    local i=1; for p in "${pools[@]}"; do v="$(get_sync_value "$p")"; printf "  %2d)  %-2s  %-20s  %s(sync=%s)%s\n" "$i" "$(status_mark "$v")" "$p" "$DIM" "$v" "$RESET"; ((i++)); done
    echo; read -r -p "  Enter numbers (space-separated) or *: " sel; echo
    local targets=(); if [[ "$sel" == "*" ]]; then targets=("${pools[@]}"); else for x in $sel; do [[ "$x" =~ ^[0-9]+$ && $x -ge 1 && $x -le ${#pools[@]} ]] && targets+=("${pools[$((x-1))]}"); done; fi
    [[ -z "${targets[*]:-}" ]] && { echo " ${I_ERR} Nothing selected."; return; }
    printf " %s %s Planned changes [sync=%s]%s\n" "$BOLD" "$I_INFO" "$val" "$RESET"; hr; printf "   · %s\n" "${targets[@]}"; echo
    if confirm "Proceed?"; then for t in "${targets[@]}"; do apply_sync "$val" "$t"; done; printf " %s Done (pools)\n" "$I_OK"; else printf " %s Cancelled\n" "$I_WARN"; fi; echo
  elif [[ "$s" == "2" ]]; then
    mapfile -t ds < <(list_datasets); [[ ${#ds[@]} -eq 0 ]] && { echo " ${I_ERR} No datasets found."; return; }
    printf " %s %s Datasets preview%s\n" "$BOLD" "$I_DS" "$RESET"; hr; printf "   · %s\n" "${ds[@]:0:25}"; [[ ${#ds[@]} -gt 25 ]] && echo "   · ... (${#ds[@]} total)"; echo
    read -r -p "  Enter exact names or regex (comma-separated): " patterns; echo
    IFS=',' read -r -a pats <<< "${patterns:-}"; declare -A chosen=()
    for d in "${ds[@]}"; do for pat in "${pats[@]}"; do pat="${pat// /}"; [[ -z "$pat" ]] && continue; echo "$d" | grep -Eq "$pat" && chosen["$d"]=1; done; done
    [[ ${#chosen[@]} -eq 0 ]] && { echo " ${I_ERR} No matches."; return; }
    printf " %s %s Planned changes [sync=%s]%s\n" "$BOLD" "$I_INFO" "$val" "$RESET"; hr; for k in "${!chosen[@]}"; do echo "   · $k"; done | sort; echo
    if confirm "Proceed?"; then for k in "${!chosen[@]}"; do apply_sync "$val" "$k"; done; printf " %s Done (datasets)\n" "$I_OK"; else printf " %s Cancelled\n" "$I_WARN"; fi; echo
  else
    echo " ${I_ERR} Invalid option."
  fi
}

main(){
  require_cmds
  [[ $EUID -ne 0 ]] && { echo " ${I_ERR} Run as root."; exit 1; }
  : >"$LOG_FILE" || { echo " ${I_ERR} Cannot write $LOG_FILE"; exit 1; }

  header
  local ENV; ENV="$(detect_env)"
  printf " %s %s Detected environment:%s %s\n" "$I_ENV" "$BOLD" "$RESET" "$ENV"; hr
  if confirm "Enable DRY-RUN (preview only)?"; then DRY_RUN=1; echo "  DRY-RUN enabled."; hr; fi

  while true; do
    echo
    printf " %s Main menu%s\n" "$BOLD" "$RESET"; hr
    printf "  %2d)  %-2s  %-18s  %s\n" 1 "$I_DISABLE" "Disable sync"    "sets sync=disabled · less writes (risk on power loss)"
    printf "  %2d)  %-2s  %-18s  %s\n" 2 "$I_REVERT"  "Revert to standard" "sets sync=standard"
    printf "  %2d)  %-2s  %-18s  %s\n" 3 "$I_INFO"    "Show pools & datasets" "includes pool-root sync status"
    printf "  %2d)  %-2s  %-18s\n"     4 "$I_SUGG"    "Environment suggestions"
    printf "  %2d)  %-2s  %-18s\n"     0 "$I_EXIT"    "Exit"
    echo
    read -r -p "  Choose: " op; echo
    case "$op" in
      1) bulk_apply disable ;;
      2) bulk_apply revert ;;
      3) show_info ;;
      4) show_suggestions "$ENV" ;;
      0) printf " %s Bye.\n" "$I_OK"; break ;;
      *) echo " ${I_ERR} Invalid option." ;;
    esac
  done
}

main "$@"
