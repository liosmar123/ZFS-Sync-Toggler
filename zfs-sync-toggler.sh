#!/usr/bin/env bash
# zfs-sync-toggler.sh
# Interactive helper to toggle ZFS sync property (disable/standard) with a polished TUI.
# ⚠️ Disabling sync reduces SSD wear but can lose the last seconds of data on sudden power loss.

set -euo pipefail

# =========[ Style / Icons ]=========
ICON_APP="💿"
ICON_ENV="🧭"
ICON_OK="✅"
ICON_WARN="⚠️"
ICON_ERR="❌"
ICON_Q="❓"
ICON_EDIT="✍️"
ICON_LIST="📃"
ICON_RUN="▶️"
ICON_BACK="↩️"
ICON_DRY="🧪"
ICON_GEAR="⚙️"
ICON_POOL="🫧"
ICON_DS="🧩"
ICON_LOG="🗒️"

# Colors
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

LOG_FILE="/var/log/zfs-sync-toggle.log"
DRY_RUN=0

# =========[ Helpers ]=========
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
run(){ if [[ $DRY_RUN -eq 1 ]]; then echo "${DIM}${ICON_DRY} DRY-RUN:${RESET} $*"; else eval "$@"; fi; }

require_cmds(){
  for c in zpool zfs awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || { echo "${RED}${ICON_ERR} Missing command:${RESET} $c"; exit 1; }
  done
}

header(){
  clear 2>/dev/null || true
  echo -e "${BOLD}${ICON_APP} ZFS Sync Toggler${RESET} ${DIM}(interactive)${RESET}"
  echo -e "${DIM}${ICON_LOG} Log: $LOG_FILE${RESET}\n"
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
  read -r -p "$(echo -e "${YELLOW}${ICON_Q} $prompt [y/N]: ${RESET}")" ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

apply_property(){
  local prop="$1" value="$2" target="$3"
  if [[ "$value" == "disabled" ]]; then
    log "${ICON_WARN} Applying ${prop}=${value} on ${target}"
  else
    log "${ICON_OK} Reverting ${prop}=${value} on ${target}"
  fi
  run "zfs set $prop=$value '$target'"
}

bulk_apply(){
  local action="$1"  # disable|revert
  local value="disabled"
  [[ "$action" == "revert" ]] && value="standard"

  echo
  echo -e "${BOLD}${ICON_GEAR} Scope selection${RESET}"
  echo -e "  1) ${ICON_POOL} By pool (inherits to children)"
  echo -e "  2) ${ICON_DS} Choose specific datasets/zvols"
  read -r -p "Select [1-2]: " scope

  if [[ "$scope" == "1" ]]; then
    mapfile -t pools < <(list_pools)
    if [[ ${#pools[@]} -eq 0 ]]; then echo -e "${RED}${ICON_ERR} No pools found.${RESET}"; return; fi

    echo
    echo -e "${ICON_POOL} Detected pools:"
    local i=1; for p in "${pools[@]}"; do echo "  $i) $p"; ((i++)); done
    read -r -p "Enter numbers separated by spaces (or * for all): " sel

    local targets=()
    if [[ "$sel" == "*" ]]; then
      targets=("${pools[@]}")
    else
      for x in $sel; do
        if [[ "$x" =~ ^[0-9]+$ ]] && (( x>=1 && x<=${#pools[@]} )); then
          targets+=("${pools[$((x-1))]}")
        fi
      done
    fi

    echo
    echo -e "${ICON_LIST} Planned changes (${BOLD}sync=${value}${RESET}):"
    printf '  - %s\n' "${targets[@]:-<none>}"
    [[ -z "${targets[*]:-}" ]] && { echo -e "${RED}${ICON_ERR} Nothing selected.${RESET}"; return; }

    if confirm "Proceed?"; then
      for t in "${targets[@]}"; do apply_property sync "$value" "$t"; done
      echo -e "${GREEN}${ICON_OK} Done (scope=pools).${RESET}"
    else
      echo -e "${YELLOW}${ICON_BACK} Cancelled.${RESET}"
    fi

  elif [[ "$scope" == "2" ]]; then
    mapfile -t datasets < <(list_datasets)
    if [[ ${#datasets[@]} -eq 0 ]]; then echo -e "${RED}${ICON_ERR} No datasets found.${RESET}"; return; fi

    echo
    echo -e "${ICON_DS} Datasets preview:"
    printf '  - %s\n' "${datasets[@]}" | head -n 25
    echo "  ... (${#datasets[@]} total)"
    echo
    read -r -p "Enter exact names or regex patterns (grep -E), comma-separated: " patterns

    IFS=',' read -r -a pats <<< "${patterns:-}"
    declare -A chosen=()
    for d in "${datasets[@]}"; do
      for pat in "${pats[@]}"; do
        pat="${pat// /}"
        [[ -z "$pat" ]] && continue
        if echo "$d" | grep -Eq "$pat"; then chosen["$d"]=1; fi
      done
    done

    if [[ ${#chosen[@]} -eq 0 ]]; then echo -e "${RED}${ICON_ERR} No matches.${RESET}"; return; fi
    echo
    echo -e "${ICON_LIST} Planned changes (${BOLD}sync=${value}${RESET}):"
    for k in "${!chosen[@]}"; do echo "  - $k"; done | sort

    if confirm "Proceed?"; then
      for k in "${!chosen[@]}"; do apply_property sync "$value" "$k"; done
      echo -e "${GREEN}${ICON_OK} Done (scope=datasets).${RESET}"
    else
      echo -e "${YELLOW}${ICON_BACK} Cancelled.${RESET}"
    fi
  else
    echo -e "${RED}${ICON_ERR} Invalid option.${RESET}"
  fi
}

menu_show_info(){
  echo -e "${ICON_POOL} Pools:"; list_pools | sed 's/^/  - /'
  echo -e "\n${ICON_DS} Datasets (first 50):"; list_datasets | head -n 50 | sed 's/^/  - /'
}

menu_show_guesses(){
  local env="$1"
  mapfile -t guesses < <(guess_targets "$env" || true)
  if [[ ${#guesses[@]} -gt 0 ]]; then
    echo -e "${ICON_LIST} Environment-based suggestions (${BOLD}${env}${RESET}):"
    for g in "${guesses[@]}"; do echo "  - $g"; done
  else
    echo -e "${YELLOW}${ICON_WARN} No automatic suggestions for ${env}.${RESET}"
  fi
}

# =========[ Main ]=========
main(){
  require_cmds
  [[ $EUID -ne 0 ]] && { echo -e "${RED}${ICON_ERR} Please run as root.${RESET}"; exit 1; }
  touch "$LOG_FILE" || { echo -e "${RED}${ICON_ERR} Cannot write log at $LOG_FILE${RESET}"; exit 1; }

  header
  local ENVIRON; ENVIRON=$(detect_env)
  echo -e "${ICON_ENV} Detected environment: ${BOLD}${ENVIRON}${RESET}\n"

  if confirm "Enable DRY-RUN (preview only)?"; then
    DRY_RUN=1
    echo -e "${ICON_DRY} DRY-RUN enabled.\n"
  fi

  while true; do
    echo -e "${BOLD}${ICON_GEAR} Main menu${RESET}"
    echo -e "  1) ${ICON_WARN} Disable sync (sync=disabled) — reduce writes, risk on power loss"
    echo -e "  2) ${ICON_OK} Revert to standard (sync=standard)"
    echo -e "  3) ${ICON_LIST} Show pools & datasets"
    echo -e "  4) ${ICON_ENV} Show environment suggestions"
    echo -e "  0) ${ICON_BACK} Exit"
    read -r -p "Choose: " op
    echo
    case "$op" in
      1) bulk_apply "disable"; echo ;;
      2) bulk_apply "revert"; echo ;;
      3) menu_show_info; echo ;;
      4) menu_show_guesses "$ENVIRON"; echo ;;
      0) echo -e "${GREEN}${ICON_OK} Bye.${RESET}"; break ;;
      *) echo -e "${RED}${ICON_ERR} Invalid option.${RESET}" ;;
    esac
  done
}

main "$@"
