#!/usr/bin/env bash

# Proxmox VE 8 to 9 upgrade helper.
# Primary reference: https://pve.proxmox.com/wiki/Upgrade_from_8_to_9

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
TARGET_SUITE="trixie"
SOURCE_SUITE="bookworm"
LOG_FILE="${LOG_FILE:-/var/log/pve8to9-upgrade-helper.log}"
APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
APT_BACKUP_BASE_DIR="${APT_BACKUP_BASE_DIR:-/root}"
PVE_CONFIG_DIR="${PVE_CONFIG_DIR:-/etc/pve}"
COROSYNC_CONFIG="${COROSYNC_CONFIG:-/etc/corosync/corosync.conf}"
CEPH_CONFIG_FILE="${CEPH_CONFIG_FILE:-/etc/ceph/ceph.conf}"

ASSUME_YES=0
CHECK_ONLY=0
NO_REBOOT=0
PVE_REPO="prompt"
CEPH_REPO="auto"

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

usage() {
  cat <<EOF
Usage: sudo ./ProxmoxVE8to9.sh [options]

Options:
  --check-only                  Run readiness checks without changing repositories or packages.
  --yes                         Assume yes for this helper's prompts. apt remains interactive.
  --pve-repo enterprise|no-subscription
                                Select the Proxmox VE 9 repository to write in deb822 format.
  --ceph-repo auto|enterprise|no-subscription|none
                                Select the Ceph Squid repository behavior. Default: auto.
  --no-reboot                   Do not offer to reboot at the end.
  -h, --help                    Show this help.

Examples:
  sudo ./ProxmoxVE8to9.sh --check-only
  sudo ./ProxmoxVE8to9.sh --pve-repo enterprise --ceph-repo enterprise
  sudo ./ProxmoxVE8to9.sh --pve-repo no-subscription --ceph-repo auto
EOF
}

log() {
  local message="$1"
  echo "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${message}" | tee -a "$LOG_FILE"
}

warn() {
  local message="$1"
  echo "${YELLOW}[WARN]${NC} ${message}" | tee -a "$LOG_FILE" >&2
}

success() {
  local message="$1"
  echo "${GREEN}[OK]${NC} ${message}" | tee -a "$LOG_FILE"
}

die() {
  local message="$1"
  echo "${RED}[ERROR]${NC} ${message}" | tee -a "$LOG_FILE" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "${prompt} yes"
    return 0
  fi

  read -r -p "${prompt} [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

run() {
  log "+ $*"
  "$@"
}

sed_in_place() {
  local expression="$1"
  local file="$2"

  if sed --version >/dev/null 2>&1; then
    sed -i "$expression" "$file"
  else
    sed -i '' "$expression" "$file"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-only)
        CHECK_ONLY=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --pve-repo)
        PVE_REPO="${2:-}"
        shift 2
        ;;
      --ceph-repo)
        CEPH_REPO="${2:-}"
        shift 2
        ;;
      --no-reboot)
        NO_REBOOT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  case "$PVE_REPO" in
    prompt|enterprise|no-subscription) ;;
    *) die "--pve-repo must be enterprise or no-subscription" ;;
  esac

  case "$CEPH_REPO" in
    auto|enterprise|no-subscription|none) ;;
    *) die "--ceph-repo must be auto, enterprise, no-subscription, or none" ;;
  esac
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

require_proxmox() {
  command -v pveversion >/dev/null 2>&1 || die "pveversion not found. This does not look like a Proxmox VE host."
}

version_major() {
  pveversion | awk -F'/' '/pve-manager/ { split($2, v, "."); print v[1]; exit }'
}

version_full() {
  pveversion | awk -F'/' '/pve-manager/ { split($2, v, " "); print v[1]; exit }'
}

check_starting_version() {
  local major full
  major="$(version_major)"
  full="$(version_full)"
  log "Detected Proxmox VE pve-manager version: ${full:-unknown}"

  case "$major" in
    8) ;;
    9)
      warn "This host is already on Proxmox VE 9. The helper will only run verification unless you continue manually."
      ;;
    *)
      die "Unsupported Proxmox VE major version '${major:-unknown}'. This helper only supports PVE 8 to 9."
      ;;
  esac
}

check_disk_space() {
  local available_kib available_gib
  available_kib="$(df --output=avail / | awk 'NR==2 {print $1}')"
  available_gib=$((available_kib / 1024 / 1024))

  if (( available_gib < 5 )); then
    die "At least 5 GiB free on / is required; found ${available_gib} GiB."
  fi

  if (( available_gib < 10 )); then
    warn "Only ${available_gib} GiB free on /. Proxmox recommends 5 GiB minimum, ideally more than 10 GiB."
  else
    success "Root filesystem has ${available_gib} GiB free."
  fi
}

check_console_and_session() {
  if [[ -n "${SSH_TTY:-}" ]] && [[ -z "${TMUX:-}" && -z "${STY:-}" ]]; then
    warn "SSH session detected without tmux/screen. Proxmox recommends a terminal multiplexer for SSH upgrades."
  fi

  if [[ -n "${PVE_GENERATING_DOCS:-}" ]]; then
    return 0
  fi

  if ! confirm "Confirm you have console/IPMI/physical access or an SSH session protected by tmux/screen."; then
    die "Console/session access was not confirmed."
  fi
}

check_backups() {
  cat <<EOF

Before continuing, confirm you have current, tested backups:
  - all VMs and containers
  - /etc/pve
  - /etc/network/interfaces and other host-specific /etc files
  - storage, firewall, and cluster configuration needed for recovery

EOF

  if ! confirm "Confirm backups are complete and restore-tested."; then
    die "Backups were not confirmed."
  fi
}

check_cluster() {
  if [[ -f "$COROSYNC_CONFIG" ]]; then
    warn "Cluster configuration detected. Upgrade one node at a time and keep the cluster healthy between nodes."
    run pvecm status || warn "pvecm status reported issues. Resolve cluster health before upgrading."
    if ! confirm "Confirm this node has been drained/migrated as needed and the cluster is healthy."; then
      die "Cluster readiness was not confirmed."
    fi
  fi
}

check_ceph() {
  if ! pve_managed_ceph_detected; then
    log "No PVE-managed local Ceph configuration detected; skipping hyper-converged Ceph version gate."
    return 0
  fi

  if ! command -v ceph >/dev/null 2>&1; then
    die "PVE-managed Ceph configuration detected, but the ceph command is not available. Verify Ceph health/version manually before upgrading."
  fi

  local ceph_version ceph_version_number ceph_major ceph_minor
  ceph_version="$(ceph --version 2>/dev/null || true)"
  ceph_version_number="$(awk '{print $3}' <<<"$ceph_version")"
  ceph_major="$(cut -d. -f1 <<<"$ceph_version_number")"
  ceph_minor="$(cut -d. -f2 <<<"$ceph_version_number")"

  if [[ -z "$ceph_version" ]]; then
    die "PVE-managed Ceph is detected but version could not be determined. Verify Ceph health/version manually before upgrading."
  fi

  log "Detected ${ceph_version}"

  if ! [[ "$ceph_major" =~ ^[0-9]+$ && "$ceph_minor" =~ ^[0-9]+$ ]]; then
    die "Could not parse PVE-managed Ceph version. Verify Ceph is Squid 19.2 before upgrading. Detected: ${ceph_version}"
  fi

  if [[ "$ceph_major" != "19" || "$ceph_minor" -lt 2 ]]; then
    die "Hyper-converged Ceph must be upgraded to Ceph Squid 19.2 before PVE 9. Detected: ${ceph_version}"
  fi
}

run_pve8to9() {
  if ! command -v pve8to9 >/dev/null 2>&1; then
    die "pve8to9 not found. Update to the latest Proxmox VE 8.4 packages first, then rerun this helper."
  fi

  log "Running pve8to9 --full. Review all warnings before continuing."
  if pve8to9 --full | tee -a "$LOG_FILE"; then
    success "pve8to9 --full completed."
  else
    warn "pve8to9 --full reported issues."
  fi

  if ! confirm "Confirm the pve8to9 output is understood and any blocking issues are fixed."; then
    die "pve8to9 output was not accepted."
  fi
}

upgrade_latest_8() {
  if [[ "$(version_major)" != "8" ]]; then
    return 0
  fi

  log "Updating current Proxmox VE 8 packages before repository migration."
  run apt update
  run apt dist-upgrade

  local full
  full="$(version_full)"
  if [[ ! "$full" =~ ^8\.4\. ]]; then
    die "Expected Proxmox VE 8.4.x before upgrading to 9.x; detected ${full:-unknown}."
  fi

  success "Host is on Proxmox VE ${full}."
}

select_repositories() {
  if [[ "$PVE_REPO" == "prompt" ]]; then
    echo
    echo "Select the Proxmox VE 9 repository:"
    echo "  1) enterprise (recommended for production with a valid subscription)"
    echo "  2) no-subscription (community/testing use; no subscription required)"
    read -r -p "Choice [1/2]: " choice
    case "$choice" in
      1) PVE_REPO="enterprise" ;;
      2) PVE_REPO="no-subscription" ;;
      *) die "Invalid repository choice." ;;
    esac
  fi

  log "Selected PVE repository: ${PVE_REPO}"
  log "Selected Ceph repository mode: ${CEPH_REPO}"
}

backup_apt_sources() {
  local backup_dir
  backup_dir="${APT_BACKUP_BASE_DIR}/pve8to9-apt-sources-backup-$(date '+%Y%m%d-%H%M%S')"
  run mkdir -p "$backup_dir"

  if [[ -f "$APT_SOURCES_LIST" ]]; then
    run cp -a "$APT_SOURCES_LIST" "$backup_dir/"
  fi

  if [[ -d "$APT_SOURCES_DIR" ]]; then
    run cp -a "$APT_SOURCES_DIR" "$backup_dir/"
  fi

  success "Backed up APT sources to ${backup_dir}."
}

comment_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed_in_place 's/^[[:space:]]*deb /# disabled by pve8to9 helper: deb /' "$file"
}

comment_matching_list_lines() {
  local file="$1"
  local pattern="$2"
  local tmp

  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v pattern="$pattern" '
    /^[[:space:]]*deb[[:space:]]/ && $0 ~ pattern {
      print "# disabled by pve8to9 helper: " $0
      next
    }
    { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

apt_source_files() {
  [[ -f "$APT_SOURCES_LIST" ]] && printf '%s\0' "$APT_SOURCES_LIST"
  [[ -d "$APT_SOURCES_DIR" ]] && find "$APT_SOURCES_DIR" -type f \( -name '*.list' -o -name '*.sources' \) -print0
}

is_official_debian_source() {
  local file="$1"
  grep -Eiq '(^|[[:space:]])(https?://)?([a-z0-9.-]+\.)?(debian\.org|debian\.net)/debian(-security)?/?([[:space:]]|$)|^[[:space:]]*URIs:[[:space:]].*(debian\.org|debian\.net)/debian(-security)?' "$file"
}

is_proxmox_source() {
  local file="$1"
  grep -Eiq 'enterprise\.proxmox\.com/debian/(pve|ceph-|pbs)|download\.proxmox\.com/debian/(pve|ceph-|pbs)' "$file"
}

disable_source_file() {
  local file="$1"
  if [[ "$file" == *.sources ]]; then
    run mv "$file" "${file}.disabled-by-pve8to9"
  else
    comment_file "$file"
  fi
}

disable_matching_deb822_stanzas() {
  local file="$1"
  local pattern="$2"
  local disabled_file="${file}.disabled-by-pve8to9"
  local tmp

  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  : > "$disabled_file"

  awk -v pattern="$pattern" -v disabled_file="$disabled_file" '
    BEGIN { RS = ""; ORS = "" }
    {
      stanza = $0
      sub(/[[:space:]]+$/, "", stanza)
      if (stanza ~ pattern) {
        print stanza "\n\n" >> disabled_file
      } else {
        print stanza "\n\n"
      }
    }
  ' "$file" > "$tmp"

  if grep -q '[^[:space:]]' "$tmp"; then
    cat "$tmp" > "$file"
  else
    rm -f "$file"
  fi

  rm -f "$tmp"
}

disable_legacy_pve_sources() {
  local file
  local pve_repo_pattern='enterprise\.proxmox\.com/debian/pve|download\.proxmox\.com/debian/pve'

  while IFS= read -r -d '' file; do
    if grep -Eq "$pve_repo_pattern" "$file"; then
      log "Disabling legacy PVE repository entries in ${file}."
      if [[ "$file" == *.sources ]]; then
        disable_matching_deb822_stanzas "$file" "$pve_repo_pattern"
      else
        comment_matching_list_lines "$file" "$pve_repo_pattern"
      fi
    fi
  done < <(apt_source_files)
}

replace_debian_suite_in_apt_sources() {
  local file
  while IFS= read -r -d '' file; do
    if grep -q "$SOURCE_SUITE" "$file" && is_official_debian_source "$file"; then
      log "Updating Debian suite names in ${file}."
      sed_in_place "s/${SOURCE_SUITE}/${TARGET_SUITE}/g" "$file"
    fi
  done < <(apt_source_files)
}

handle_third_party_bookworm_sources() {
  local file
  local files=()

  while IFS= read -r -d '' file; do
    if grep -q "$SOURCE_SUITE" "$file" && ! is_official_debian_source "$file" && ! is_proxmox_source "$file"; then
      files+=("$file")
    fi
  done < <(apt_source_files)

  if [[ "${#files[@]}" -eq 0 ]]; then
    return 0
  fi

  warn "Found third-party Bookworm APT sources. Proxmox requires third-party repositories/packages to be verified for Debian Trixie compatibility before upgrading."
  printf '  %s\n' "${files[@]}" | tee -a "$LOG_FILE" >&2

  if confirm "Disable these third-party Bookworm sources now?"; then
    for file in "${files[@]}"; do
      log "Disabling third-party Bookworm source ${file}."
      disable_source_file "$file"
    done
  else
    die "Review or disable third-party Bookworm sources before repository migration."
  fi
}

write_pve_repository() {
  case "$PVE_REPO" in
    enterprise)
      cat > "${APT_SOURCES_DIR}/pve-enterprise.sources" <<EOF
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      ;;
    no-subscription)
      cat > "${APT_SOURCES_DIR}/proxmox.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      ;;
  esac
}

ceph_repo_needed() {
  pve_managed_ceph_detected || [[ -f "${APT_SOURCES_DIR}/ceph.list" ]] || [[ -f "${APT_SOURCES_DIR}/ceph.sources" ]]
}

pve_managed_ceph_detected() {
  [[ -f "${PVE_CONFIG_DIR}/ceph.conf" ]] || [[ -f "$CEPH_CONFIG_FILE" && -d "${PVE_CONFIG_DIR}/priv/ceph" ]]
}

write_ceph_repository() {
  if [[ "$CEPH_REPO" == "none" ]]; then
    log "Skipping Ceph repository changes by request."
    return 0
  fi

  if [[ "$CEPH_REPO" == "auto" ]]; then
    if ! ceph_repo_needed; then
      log "No local Ceph installation/repository detected; skipping Ceph repository."
      return 0
    fi
    CEPH_REPO="$PVE_REPO"
  fi

  case "$CEPH_REPO" in
    enterprise)
      cat > "${APT_SOURCES_DIR}/ceph.sources" <<EOF
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      ;;
    no-subscription)
      cat > "${APT_SOURCES_DIR}/ceph.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      ;;
  esac

  if [[ -f "${APT_SOURCES_DIR}/ceph.list" ]]; then
    log "Disabling legacy Ceph list repository."
    comment_file "${APT_SOURCES_DIR}/ceph.list"
  fi
}

disable_backports() {
  local file
  local backports_pattern='(^[[:space:]]*deb .*backports|^[[:space:]]*Suites:[[:space:]].*backports)'

  while IFS= read -r -d '' file; do
    if grep -Eq "$backports_pattern" "$file"; then
      warn "Disabling backports repository in ${file}; Proxmox does not test this upgrade with backports."
      if [[ "$file" == *.sources ]]; then
        disable_matching_deb822_stanzas "$file" 'Suites:[[:space:]].*backports'
      else
        comment_matching_list_lines "$file" 'backports'
      fi
    fi
  done < <(apt_source_files)
}

configure_repositories() {
  select_repositories
  backup_apt_sources
  handle_third_party_bookworm_sources
  replace_debian_suite_in_apt_sources
  disable_legacy_pve_sources
  write_pve_repository
  write_ceph_repository
  disable_backports
  success "Repository files updated for Debian Trixie / Proxmox VE 9."
}

pre_upgrade_known_issue_checks() {
  if dpkg-query -W -f='${Status}\n' linux-image-amd64 2>/dev/null | grep -q 'install ok installed'; then
    warn "linux-image-amd64 is installed. Official docs say it can conflict with current PVE 9 setups."
    if confirm "Remove linux-image-amd64 now?"; then
      run apt remove linux-image-amd64
    else
      die "Remove linux-image-amd64 manually before dist-upgrade."
    fi
  fi

  if dpkg-query -W -f='${Status}\n' systemd-boot 2>/dev/null | grep -q 'install ok installed'; then
    warn "systemd-boot meta-package is installed. pve8to9 may recommend removing it for PVE-managed boot setups."
  fi

  if systemctl list-unit-files systemd-journald-audit.socket >/dev/null 2>&1; then
    warn "Debian Trixie can emit excessive audit logs during upgrade if systemd-journald-audit.socket stays enabled."
    if confirm "Disable and stop systemd-journald-audit.socket before upgrade?"; then
      run systemctl disable --now systemd-journald-audit.socket || warn "Could not disable systemd-journald-audit.socket."
    fi
  fi
}

perform_distribution_upgrade() {
  log "Refreshing package indexes against Trixie repositories."
  run apt update
  run apt policy

  if ! confirm "Confirm apt update/policy output is clean and shows only intended Bookworm/Trixie transition repositories."; then
    die "Repository verification was not confirmed."
  fi

  pre_upgrade_known_issue_checks

  log "Starting apt dist-upgrade. Keep this interactive so package conffile prompts can be answered deliberately."
  run apt dist-upgrade
}

post_upgrade_checks() {
  log "Running pve8to9 after dist-upgrade."
  if command -v pve8to9 >/dev/null 2>&1; then
    pve8to9 --full | tee -a "$LOG_FILE" || warn "pve8to9 still reports issues after upgrade."
  else
    warn "pve8to9 is not available after upgrade."
  fi

  log "Current pveversion output:"
  pveversion | tee -a "$LOG_FILE" || true

  log "Current kernel: $(uname -r)"

  if [[ -d /sys/firmware/efi ]]; then
    log "UEFI boot detected."
    if mountpoint -q /boot/efi && findmnt -n -o SOURCE / | grep -qi lvm; then
      warn "UEFI with root on LVM detected. Official docs recommend ensuring grub-efi-amd64 is installed."
      if confirm "Install grub-efi-amd64 now?"; then
        run apt install grub-efi-amd64
      fi
    fi
  fi

  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required."
  else
    warn "A reboot is still recommended after a major Proxmox VE upgrade to load the PVE 9 kernel and services."
  fi

  if [[ "$NO_REBOOT" -eq 0 ]] && confirm "Reboot now?"; then
    run reboot
  else
    log "Reboot skipped. Reboot manually before considering the upgrade complete."
  fi
}

main() {
  parse_args "$@"
  require_root
  touch "$LOG_FILE"

  cat <<EOF
Proxmox VE 8 to 9 Upgrade Helper v${SCRIPT_VERSION}

This helper follows the official Proxmox 8-to-9 flow:
  1. update to the latest PVE 8.4 packages
  2. run pve8to9 --full
  3. migrate APT repositories to Debian Trixie / PVE 9 deb822 sources
  4. run apt dist-upgrade interactively
  5. run pve8to9 --full again and reboot

Log: ${LOG_FILE}
EOF

  require_proxmox
  check_starting_version
  check_disk_space
  check_console_and_session
  check_backups
  check_cluster
  check_ceph

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    run_pve8to9
    success "Check-only mode completed. No repository or package changes were made by this helper."
    exit 0
  fi

  if [[ "$(version_major)" == "9" ]]; then
    post_upgrade_checks
    exit 0
  fi

  upgrade_latest_8
  run_pve8to9
  configure_repositories
  perform_distribution_upgrade
  post_upgrade_checks
  success "Upgrade helper completed. Clear the browser cache and verify the web UI after reboot."
}

if [[ "${PVE8TO9_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
