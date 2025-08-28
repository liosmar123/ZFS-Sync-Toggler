#!/usr/bin/env bash
# zfs-sync-toggler.sh
# Interactive helper to toggle ZFS sync property (disable/standard) with a clean TUI.
# ⚠️ Disabling sync reduces SSD wear but can lose the last seconds of data on sudden power loss.

set -euo pipefail

# =========[ Style / Icons ]=========
# Iconos simples y “universales”
ICON_APP="🛠 "
ICON_ENV="🧭 "
ICON_OK="✅ "
ICON_WARN="⚠️ "
ICON_ERR="❌ "
ICON_Q="❓ "
ICON_LIST="📋 "
ICON_RUN="▶️ "
ICON_BACK="↩️ "
ICON_DRY="🧪 "
ICON_GEAR="⚙️ "
ICON_POOL="🫧 "
ICON_DS="🧩 "
ICON_LOG="🗒️ "

# Colores
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

# “Badges” para estados de sync
CHK_OK="${GREEN}✅${RESET}"
CHK_BAD="${RED}❌${RESET}"

LOG_FILE="/var/log/zfs-sync-toggle.log"
DRY_RUN=0

# =========[ Helpers ]=========
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
run(){ if [[ $DRY_RUN -eq 1 ]]; then echo "${DIM}${ICON_DRY}DRY-RUN:${RESET} $*"; else eval "$@"; fi; }

require_cmds(){
  for c in zpool zfs awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || { echo "${RED}${ICON_ERR}Missing command:${RESET} $c"; exit 1; }
  done
}

header(){
  clear 2>/dev/null || true
  echo -e "${BOLD}${ICON_APP}ZFS Sync Toggler${RESET}  ${DIM}(interactive)${RESET}"
  echo -e "${DIM}${ICON_LOG}Log:${RESET} $LOG_FILE\n"
}

detect_env(){
  local os_id=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    case "${os_id,,}" in
      proxmox)   echo "Proxmox"; return;;
      debian|ubuntu)
        if ls /etc | grep -qi truenas; then echo "TrueNAS SCALE"; return; fi
        echo "Linux"; return;;
      *) echo "Linux"; return;;
    esac
  else
    if uname -s | grep -qi freebsd; then echo "TrueNAS CORE"; return; fi
  fi
  echo "Unknown"
}

list_pools(){ zpool list -H -o name 2>/dev/null | awk 'NF'; }
list_datasets(){ zfs list -H -o name -t filesystem,volume 2>/dev/null | awk 'NF'; }

get_sync_value(){
  # Devuelve el valor de 'sync' para un dataset (pool root incluido)
  local ds="$1"
  zfs get -H -o value sync "$ds" 2>/dev/null || echo "unknown"
}

get_sync_status_icon(){
  # ✅ si sync=disabled, ❌ en cualquier otro valor (standard, inherited distinto, unknown)
  local ds="$1"
  local val; val="$(get_sync_value "$ds")"
  if [[ "$val" == "disabled" ]]; then
    echo -e "$CHK_OK"
  else
    echo -e "$CHK_BAD"
  fi
}

guess_targets(){
  local env="$1"
  case "$env" in
    Proxmox)
      if [[ -f /etc/pve/storage.cfg ]]; then
        awk '
          $1=="zfspool" {in_zfs=1; pool=""; next}
          in_zfs && $1 ~ /^pool:/ {pool=$2}
          in_zfs && NF==0 { if(pool!="") print pool; in_zfs=0 }
          END{ if(in_zfs && pool!="") print pool }
        ' /etc/pve/storage.cfg | sort -u
      fi
      ;;
    "TrueNAS SCALE"|"TrueNAS CORE")
      list_datasets | grep -Ei 'share|smb|vm|kvm|iscsi|nfs|esx|hyper|virt' || true
      ;;
    *) : ;;
  esac
}

confirm(){
  local prompt="$1"
  read -r -p "$(echo -e "  ${YELLOW}${ICON_Q}${prompt} [y/N]: ${RESET}")" ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

apply_property(){
  local prop="$1" value="$2" target="$3"
  if [[ "$value" == "disabled" ]]; then
    log "Applying ${prop}=${value} on ${target}"
  else
    log "Reverting ${prop}=${value} on ${target}"
  fi
  run "zfs set $prop=$value '$target'"
}

menu_show_info(){
  echo -e " ${ICON_POOL}${BOLD}Pools (with sync status on root dataset)${RESET}"
  local i=1
  while read -r p; do
    [[ -z "$p" ]] && continue
    local icon; icon="$(get_sync_status_icon "$p")"
    local val; val="$(get_sync_value "$p")"
    printf "   %2d) %b  %s  %s%s%s\n" "$i" "$icon" "$p" "${DIM}(" "$val" ")${RESET}"
    ((i++))
  done < <(list_pools)
  echo

  echo -e " ${ICON_DS}${BOLD}Datasets (first 40)${RESET}"
  list_datasets | head -n 40 | sed 's/^/    · /'
  echo
}

menu_show_guesses(){
  local env="$1"
  mapfile -t guesses < <(guess_targets "$env" || true)
  if [[ ${#guesses[@]} -gt 0 ]]; then
    echo -e " ${ICON_LIST}${BOLD}Environment suggestions${RESET}  ${DIM}[${env}]${RESET}"
    for g in "${guesses[@]}"; do echo "    · $g"; done
  else
    echo -e " ${ICON_WARN}No automatic suggestions for ${env}."
  fi
  echo
}

bulk_apply(){
  local action="$1"  # disable|revert
  local value="disabled"
  [[ "$action" == "revert" ]] && value="standard"

  echo
  echo -e " ${ICON_GEAR}${BOLD}Scope selection${RESET}"
  echo -e "   1  ${ICON_POOL}  By pool  ${DIM}· inherits to children${RESET}"
  echo -e "   2  ${ICON_DS}  Specific datasets/zvols  ${DIM}· regex support (grep -E)${RESET}"
  echo
  read -r -p "  Select [1-2]: " scope
  echo

  if [[ "$scope" == "1" ]]; then
    mapfile -t pools < <(list_pools)
    if [[ ${#pools[@]} -eq 0 ]]; then echo -e " ${RED}${ICON_ERR}No pools found.${RESET}"; return; fi

    echo -e " ${ICON_POOL}${BOLD}Detected pools${RESET}  ${DIM}(with sync status)${RESET}"
    local i=1
    for p in "${pools[@]}"; do
      local icon; icon="$(get_sync_status_icon "$p")"
      local val; val="$(get_sync_value "$p")"
      printf "   %2d) %b  %s  %s%s%s\n" "$i" "$icon" "$p" "${DIM}(" "$val" ")${RESET}"
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

    if [[ -z "${targets[*]:-}" ]]; then
      echo -e " ${RED}${ICON_ERR}Nothing selected.${RESET}"
      return
    fi

    echo -e " ${ICON_LIST}${BOLD}Planned changes${RESET}  ${DIM}[sync=${value}]${RESET}"
    printf "    · %s\n" "${targets[@]}"
    echo
    if confirm "Proceed?"; then
      for t in "${targets[@]}"; do apply_property sync "$value" "$t"; done
      echo -e " ${GREEN}${ICON_OK}Done (scope=pools).${RESET}\n"
    else
      echo -e " ${YELLOW}${ICON_BACK}Cancelled.${RESET}\n"
    fi

  elif [[ "$scope" == "2" ]]; then
    mapfile -t datasets < <(list_datasets)
    if [[ ${#datasets[@]} -eq 0 ]]; then echo -e " ${RED}${ICON_ERR}No datasets found.${RESET}"; return; fi

    echo -e " ${ICON_DS}${BOLD}Datasets preview${RESET}"
    printf "    · %s\n" "${datasets[@]:0:25}"
    [[ ${#datasets[@]} -gt 25 ]] && echo "    · ... (${#datasets[@]} total)"
    echo
    read -r -p "  Enter exact names or regex patterns (grep -E), comma-separated: " patterns
    echo

    IFS=',' read -r -a pats <<< "${patterns:-}"
    declare -A chosen=()
    for d in "${datasets[@]}"; do
      for pat in "${pats[@]}"; do
        pat="${pat// /}"
        [[ -z "$pat" ]] && continue
        if echo "$d" | grep -Eq "$pat"; then chosen["$d"]=1; fi
      done
    done

    if [[ ${#chosen[@]} -eq 0 ]]; then echo -e " ${RED}${ICON_ERR}No matches.${RESET}"; return; fi

    echo -e " ${ICON_LIST}${BOLD}Planned changes${RESET}  ${DIM}[sync=${value}]${RESET}"
    for k in "${!chosen[@]}"; do echo "    · $k"; done | sort
    echo
    if confirm "Proceed?"; then
      for k in "${!chosen[@]}"; do apply_property sync "$value" "$k"; done
      echo -e " ${GREEN}${ICON_OK}Done (scope=datasets).${RESET}\n"
    else
      echo -e " ${YELLOW}${ICON_BACK}Cancelled.${RESET}\n"
    fi
  else
    echo -e " ${RED}${ICON_ERR}Invalid option.${RESET}\n"
  fi
}

main(){
  require_cmds
  [[ $EUID -ne 0 ]] && { echo -e " ${RED}${ICON_ERR}Please run as root.${RESET}"; exit 1; }
  touch "$LOG_FILE" || { echo -e " ${RED}${ICON_ERR}Cannot write log at $LOG_FILE${RESET}"; exit 1; }

  header
  local ENVIRON; ENVIRON=$(detect_env)
  echo -e " ${ICON_ENV}${BOLD}Detected environment:${RESET} ${ENVIRON}\n"

  if confirm "Enable DRY-RUN (preview only)?"; then
    DRY_RUN=1
    echo -e " ${ICON_DRY}DRY-RUN enabled.\n"
  fi

  while true; do
    echo -e " ${BOLD}${ICON_GEAR}Main menu${RESET}"
    echo -e "   1  ▶️   Disable sync  ${DIM}· sets sync=disabled (less writes, risk on power loss)${RESET}"
    echo -e "   2  🔄   Revert to standard  ${DIM}· sets sync=standard${RESET}"
    echo -e "   3  📊   Show pools & datasets  ${DIM}· includes pool sync status${RESET}"
    echo -e "   4  🧭   Show environment suggestions"
    echo -e "   0  🚪   Exit"
    echo
    read -r -p "  Choose: " op
    echo
    case "$op" in
      1) bulk_apply "disable";;
      2) bulk_apply "revert";;
      3) menu_show_info;;
      4) menu_show_guesses "$ENVIRON";;
      0) echo -e " ${GREEN}${ICON_OK}Bye.${RESET}"; break;;
      *) echo -e " ${RED}${ICON_ERR}Invalid option.${RESET}\n";;
    esac
  done
}

main "$@"
