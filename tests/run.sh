#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "$pattern" "$file" || fail "expected ${file} to contain ${pattern}"
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Eq "$pattern" "$file"; then
    fail "expected ${file} not to contain ${pattern}"
  fi
}

assert_file_exists() {
  local file="$1"
  [[ -f "$file" ]] || fail "expected ${file} to exist"
}

assert_file_missing() {
  local file="$1"
  [[ ! -e "$file" ]] || fail "expected ${file} to be missing"
}

reset_fixture() {
  local name="$1"
  FIXTURE_DIR="${TMP_DIR}/${name}"
  APT_SOURCES_LIST="${FIXTURE_DIR}/etc/apt/sources.list"
  APT_SOURCES_DIR="${FIXTURE_DIR}/etc/apt/sources.list.d"
  APT_BACKUP_BASE_DIR="${FIXTURE_DIR}/root"
  PVE_CONFIG_DIR="${FIXTURE_DIR}/etc/pve"
  CEPH_CONFIG_FILE="${FIXTURE_DIR}/etc/ceph/ceph.conf"
  LOG_FILE="${FIXTURE_DIR}/helper.log"

  export APT_SOURCES_LIST APT_SOURCES_DIR APT_BACKUP_BASE_DIR PVE_CONFIG_DIR CEPH_CONFIG_FILE LOG_FILE

  mkdir -p "$APT_SOURCES_DIR" "$APT_BACKUP_BASE_DIR" "$PVE_CONFIG_DIR" "$(dirname "$CEPH_CONFIG_FILE")"
  : > "$APT_SOURCES_LIST"
  : > "$LOG_FILE"
}

load_script() {
  # shellcheck disable=SC1091
  PVE8TO9_SOURCE_ONLY=1 source "${ROOT_DIR}/ProxmoxVE8to9.sh"
  ASSUME_YES=1
  PVE_REPO="no-subscription"
  CEPH_REPO="none"
}

test_third_party_bookworm_list_is_disabled_not_rewritten() {
  reset_fixture "third-party-list"
  load_script

  cat > "$APT_SOURCES_LIST" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF

  cat > "${APT_SOURCES_DIR}/vendor.list" <<'EOF'
deb https://packages.example.invalid/debian bookworm main
EOF

  handle_third_party_bookworm_sources
  replace_debian_suite_in_apt_sources

  assert_file_contains "$APT_SOURCES_LIST" 'trixie'
  assert_file_not_contains "$APT_SOURCES_LIST" 'bookworm'
  assert_file_contains "${APT_SOURCES_DIR}/vendor.list" '^# disabled by pve8to9 helper: deb https://packages\.example\.invalid/debian bookworm main$'
}

test_third_party_bookworm_deb822_is_moved_not_rewritten() {
  reset_fixture "third-party-sources"
  load_script

  cat > "${APT_SOURCES_DIR}/vendor.sources" <<'EOF'
Types: deb
URIs: https://packages.example.invalid/debian
Suites: bookworm
Components: main
EOF

  handle_third_party_bookworm_sources
  replace_debian_suite_in_apt_sources

  assert_file_missing "${APT_SOURCES_DIR}/vendor.sources"
  assert_file_exists "${APT_SOURCES_DIR}/vendor.sources.disabled-by-pve8to9"
  assert_file_contains "${APT_SOURCES_DIR}/vendor.sources.disabled-by-pve8to9" '^Suites: bookworm$'
}

test_deb822_backports_is_disabled() {
  reset_fixture "deb822-backports"
  load_script

  cat > "${APT_SOURCES_DIR}/debian-backports.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm-backports
Components: main
EOF

  disable_backports

  assert_file_missing "${APT_SOURCES_DIR}/debian-backports.sources"
  assert_file_exists "${APT_SOURCES_DIR}/debian-backports.sources.disabled-by-pve8to9"
}

test_ceph_client_only_host_is_not_blocked() {
  reset_fixture "ceph-client-only"
  load_script

  local bin_dir="${FIXTURE_DIR}/bin"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/ceph" <<'EOF'
#!/usr/bin/env bash
echo "ceph version 18.2.7"
EOF
  chmod +x "${bin_dir}/ceph"
  PATH="${bin_dir}:${PATH}" check_ceph
}

test_pve_managed_ceph_blocks_old_major() {
  reset_fixture "pve-managed-ceph"
  load_script

  mkdir -p "$PVE_CONFIG_DIR"
  : > "${PVE_CONFIG_DIR}/ceph.conf"

  local bin_dir="${FIXTURE_DIR}/bin"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/ceph" <<'EOF'
#!/usr/bin/env bash
echo "ceph version 18.2.7"
EOF
  chmod +x "${bin_dir}/ceph"

  if (PATH="${bin_dir}:${PATH}" check_ceph); then
    fail "expected old PVE-managed Ceph to block upgrade"
  fi
}

test_pve_managed_ceph_accepts_squid() {
  reset_fixture "pve-managed-ceph-squid"
  load_script

  mkdir -p "$PVE_CONFIG_DIR"
  : > "${PVE_CONFIG_DIR}/ceph.conf"

  local bin_dir="${FIXTURE_DIR}/bin"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/ceph" <<'EOF'
#!/usr/bin/env bash
echo "ceph version 19.2.1"
EOF
  chmod +x "${bin_dir}/ceph"

  PATH="${bin_dir}:${PATH}" check_ceph
}

main() {
  local tests=(
    test_third_party_bookworm_list_is_disabled_not_rewritten
    test_third_party_bookworm_deb822_is_moved_not_rewritten
    test_deb822_backports_is_disabled
    test_ceph_client_only_host_is_not_blocked
    test_pve_managed_ceph_blocks_old_major
    test_pve_managed_ceph_accepts_squid
  )

  local test_name
  for test_name in "${tests[@]}"; do
    "$test_name"
    echo "ok - ${test_name}"
  done
}

main "$@"
