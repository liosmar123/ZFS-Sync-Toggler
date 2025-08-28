#!/usr/bin/env bash
# zfs-sync-toggler.sh (v1.2)
# Toggle ZFS sync property (disable/standard) with a clean, spaced TUI.
# ⚠️ sync=disabled reduce writes (SSD wear) but risks losing last seconds of data on power loss.

set -euo pipefail

# ===== Style / Icons =====
ICON_APP="🛠"
ICON_ENV="🧭"
ICON_DISABLE="🚫"
ICON_REVERT="↩️"
ICON_INFO="ℹ️"
ICON_SUGG="🧭"
ICON_EXIT="🚪"
ICON_POOL="🫧"
ICON_DS="🧩"
ICON_LIST="📋"
ICON_WARN="⚠️"
ICON_ERR="❌"
ICON_OK="✅"
ICON_DRY="🧪"

if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

CHK_OK="${GREEN}${ICON_OK}${RESET}"
CHK_BAD="${RED}${ICON_ERR}${RESET}"

LOG_FILE="/var/log/zfs-sync-toggle.log"
DRY_RUN=0

pad(){ printf "%-2s %-16s" "" "$1"; }   # left padding + column spacing
hr(){  echo -e "  ${DIM}────────────────────────────────────────────────────────${RESET}"; }

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
run(){ if [[ $DRY_RUN -eq 1 ]]; then echo "${DIM}${ICON_DRY} DRY-RUN:${RESET} $*"; else eval "$@"; fi; }

require_cmds(){
  for c in zpool zfs awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || { echo " ${RED}${ICON_ERR} Missing command:${RESET} $c"; exit 1; }
  done
}

header(){
  clear 2>/dev/null || true
  echo -e " ${BOLD}${ICON_APP}  ZFS Sync Toggler${RESET}   ${DIM}(interactive)${RESET}"
  echo -e "  ${DIM}Log:${RESET} $LOG_FILE"
  hr
}

detect_env(){
  # TrueNAS Community 25 es Linux-based
  if grep -Eiqs 'truenas' /etc/*release 2>/dev/null || [[ -e /etc/truenas-install ]]; then
    echo "TrueNAS Community (Linux base)"
    return
  fi
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID,,}" in
      proxmox) echo "Proxmox"; return;;
      debian|ubuntu) echo "Linux"; return;;
      *) echo "Linux"; return;;
    esac
  fi
  if uname -s | grep -qi freebsd; then echo "TrueNAS CORE"; return; fi
  echo "Unknown"
}

list_pools(){ zpool list -H -o name 2>/dev/null | awk 'NF'; }
list_datasets(){ zfs list -H -o name -t filesystem,volume 2>/dev/null | awk 'NF'; }
get_sync_value(){ zfs get -H -o value sync "$1" 2>/dev/null || echo "unknown"; }
sync_icon(){
  local v; v="$(get_sync_value "$1")"
  [[ "$v" == "disabled" ]] && echo -e "$CHK_OK" || echo -e "$CHK_BAD"
}

confirm(){
  local prompt="$1"
  read -r -p "$(echo -e "  ${YELLOW}${ICON_WARN} ${prompt} [y/N]: ${RESET}")" ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

apply_prop(){
  local val="$1" tgt="$2"
  local verb="Applying"; [[ "$val" == "standard" ]] && verb="Reverting"
  log "$verb sync=$val on $tgt"
  run "zfs set sync=$val '$tgt'"
}

# ===== Menus =====
show_info(){
  echo
  echo -e " ${BOLD}${ICON_POOL}  Pools (root dataset sync status)${RESET}"
  hr
  local i=1
  while read -r p; do
    [[ -z "$p" ]] && continue
    local icn val; icn="$(sync_icon "$p")"; val="$(get_sync_value "$p")"
    printf "   %2d)  %b  %-20s  ${DIM}(sync=%s)${RESET}\n" "$i" "$icn" "$p" "$val"
    ((i++))
  done < <(list_pools)
  echo
  echo -e " ${BOLD}${ICON_DS}  Datasets (first 40)${RESET}"
  hr
  list_datasets | head -n 40 | sed 's/^/    · /'
  echo
}

show_suggestions(){
  local env="$1"
  echo
  echo -e " ${BOLD}${ICON_SUGG}  Environment suggestions  ${DIM}[${env}]${RESET}"
  hr
  case "$env" in
    Proxmox)
      if [[ -f /etc/pve/storage.cfg ]]; then
        awk '$1=="zfspool"{in=1;next} in && /^pool:/{print "    · "$2}
             NF==0{in=0}' /etc/pve/storage.cfg | sort -u || true
      else
        echo "    · No zfspool storages found."
      fi
      ;;
    "TrueNAS Community (Linux base)")
      list_datasets | grep -Ei 'vm|kvm|iscsi|smb|nfs|virt' | sed 's/^/    · /' || echo "    · (no obvious targets)"
      ;;
    *)
      echo "    · Review datasets hosting VMs/SMB/NFS/iSCSI."
      ;;
  esac
  echo
}

bulk_apply(){
  local mode="$1" val="disabled"
  [[ "$mode" == "revert" ]] && val="standard"

  echo
  echo -e " ${BOLD}${ICON_LIST}  Scope selection${RESET}"
  hr
  pad "1) ${ICON_POOL}  By pool";      echo -e "${DIM}inherits to children${RESET}"
  pad "2) ${ICON_DS}   Specific datasets/zvols"; echo -e "${DIM}regex (grep -E) supported${RESET}"
  echo
  read -r -p "  Select [1-2]: " scope
  echo

  if [[ "$scope" == "1" ]]; then
    mapfile -t pools < <(list_pools)
    [[ ${#pools[@]} -eq 0 ]] && { echo " ${RED}${ICON_ERR} No pools found.${RESET}"; return; }

    echo -e " ${BOLD}${ICON_POOL}  Detected pools${RESET}  ${DIM}(with sync status)${RESET}"
    hr
    local i=1
    for p in "${pools[@]}"; do
      printf "   %2d)  %b  %-20s  ${DIM}(sync=%s)${RESET}\n" \
        "$i" "$(sync_icon "$p")" "$p" "$(get_sync_value "$p")"
      ((i++))
    done
    echo
    read -r -p "  Enter numbers separated by spaces (or * for all): " sel
    echo

    local targets=()
    if [[ "${sel:-}" == "*" ]]; then
      targets=("${pools[@]}")
    else
      for x in $sel; do
        if [[ "$x" =~ ^[0-9]+$ ]] && (( x>=1 && x<=${#pools[@]} )); then
          targets+=("${pools[$((x-1))]}")
        fi
      done
    fi
    [[ -z "${targets[*]:-}" ]] && { echo " ${RED}${ICON_ERR} Nothing selected.${RESET}"; return; }

    echo -e " ${BOLD}${ICON_LIST}  Planned changes  ${DIM}[sync=${val}]${RESET}"
    hr
    printf "    · %s\n" "${targets[@]}"
    echo
    if confirm "Proceed?"; then
      for t in "${targets[@]}"; do apply_prop "$val" "$t"; done
      echo -e " ${GREEN}${ICON_OK} Done (pools).${RESET}\n"
    else
      echo -e " ${YELLOW}${ICON_WARN} Cancelled.${RESET}\n"
    fi

  elif [[ "$scope" == "2" ]]; then
    mapfile -t dsets < <(list_datasets)
    [[ ${#dsets[@]} -eq 0 ]] && { echo " ${RED}${ICON_ERR} No datasets found.${RESET}"; return; }

    echo -e " ${BOLD}${ICON_DS}  Datasets preview${RESET}"
    hr
    printf "    · %s\n" "${dsets[@]:0:25}"
    [[ ${#dsets[@]} -gt 25 ]] && echo "    · ... (${#dsets[@]} total)"
    echo
    read -r -p "  Enter exact names or regex patterns (comma-separated): " patterns
    echo
    IFS=',' read -r -a pats <<< "${patterns:-}"
    declare -A chosen=()
    for d in "${dsets[@]}"; do
      for pat in "${pats[@]}"; do
        pat="${pat// /}"
        [[ -z "$pat" ]] && continue
        if echo "$d" | grep -Eq "$pat"; then chosen["$d"]=1; fi
      done
    done
    [[ ${#chosen[@]} -eq 0 ]] && { echo " ${RED}${ICON_ERR} No matches.${RESET}"; return; }

    echo -e " ${BOLD}${ICON_LIST}  Planned changes  ${DIM}[sync=${val}]${RESET}"
    hr
    for k in "${!chosen[@]}"; do echo "    · $k"; done | sort
    echo
    if confirm "Proceed?"; then
      for k in "${!chosen[@]}"; do apply_prop "$val" "$k"; done
      echo -e " ${GREEN}${ICON_OK} Done (datasets).${RESET}\n"
    else
      echo -e " ${YELLOW}${ICON_WARN} Cancelled.${RESET}\n"
    fi
  else
    echo -e " ${RED}${ICON_ERR} Invalid option.${RESET}\n"
  fi
}

main(){
  require_cmds
  [[ $EUID -ne 0 ]] && { echo -e " ${RED}${ICON_ERR} Please run as root.${RESET}"; exit 1; }
  touch "$LOG_FILE" || { echo -e " ${RED}${ICON_ERR} Cannot write log at $LOG_FILE${RESET}"; exit 1; }

  header
  local ENV; ENV="$(detect_env)"
  echo -e "  ${ICON_ENV} ${BOLD}Detected environment:${RESET} ${ENV}"
  hr

  if confirm "Enable DRY-RUN (preview only)?"; then
    DRY_RUN=1
    echo -e "  ${ICON_DRY} DRY-RUN enabled."
    hr
  fi

  while true; do
    echo
    echo -e " ${BOLD}Main menu${RESET}"
    hr
    pad "1) ${ICON_DISABLE}  Disable sync";          echo -e "${DIM}sets sync=disabled · less writes (risk on power loss)${RESET}"
    pad "2) ${ICON_REVERT}  Revert to standard";     echo -e "${DIM}sets sync=standard${RESET}"
    pad "3) ${ICON_INFO}    Show pools & datasets";  echo -e "${DIM}includes pool-root sync status${RESET}"
    pad "4) ${ICON_SUGG}    Environment suggestions"
    pad "0) ${ICON_EXIT}    Exit"
    echo
    read -r -p "  Choose: " op
    echo
    case "$op" in
      1) bulk_apply "disable" ;;
      2) bulk_apply "revert" ;;
      3) show_info ;;
      4) show_suggestions "$ENV" ;;
      0) echo -e " ${GREEN}${ICON_OK} Bye.${RESET}"; break ;;
      *) echo -e " ${RED}${ICON_ERR} Invalid option.${RESET}" ;;
    esac
  done
}

main "$@"
