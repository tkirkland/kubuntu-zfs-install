#!/bin/bash
# Test script: Namespace isolation vs traditional chroot cleanup
#
# Demonstrates that traditional mount --rbind/--make-rslave chroot leaves
# kernel mount references that prevent zpool export, while unshare-wrapped
# chroot cleans up automatically via mount namespace isolation.
#
# Requirements: root, zfsutils-linux, util-linux (unshare)
# Usage: sudo bash test_namespace_cleanup.sh

set -euo pipefail

#------------------------------------------------------------------------------
# Color output helpers
#------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# bashsupport disable=BP5008,BP5001
{
  info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
  success() { echo -e "${GREEN}[OK]${NC} $*"; }
  warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
  error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
  fatal()   { error "$*"; exit 1; }
}

#------------------------------------------------------------------------------
# Global variables
#------------------------------------------------------------------------------
readonly TEST_DIR="/tmp/zfs-namespace-test"
readonly POOL_NAME="testpool"
readonly MOUNT_ROOT="/tmp/zfs-ns-mnt"

VDEV_FILES=()
for i in 1 2 3; do
  VDEV_FILES+=("${TEST_DIR}/vdev${i}.img")
done
readonly VDEV_FILES

#------------------------------------------------------------------------------
# Pre-flight checks
#------------------------------------------------------------------------------
preflight_checks() {
  info "Running pre-flight checks..."

  [[ $EUID -eq 0 ]] || fatal "This script must be run as root. Use: sudo $0"

  local cmd
  for cmd in zpool zfs unshare truncate; do
    command -v "$cmd" &>/dev/null || fatal "Required command '$cmd' not found."
  done

  success "Pre-flight checks passed."
}

#------------------------------------------------------------------------------
# Cleanup trap - always runs on exit
#------------------------------------------------------------------------------
cleanup_test_infra() {
  info "Cleaning up test infrastructure..."

  # Unmount any leftover bind mounts
  for mnt in "${MOUNT_ROOT}/dev" "${MOUNT_ROOT}/proc" "${MOUNT_ROOT}/sys"; do
    if mountpoint -q "$mnt" 2>/dev/null; then
      umount -R "$mnt" 2>/dev/null || true
    fi
  done

  # Unmount pool root
  if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
    umount -R "$MOUNT_ROOT" 2>/dev/null || true
  fi

  # Destroy pool if it exists
  if zpool list "$POOL_NAME" &>/dev/null; then
    zpool destroy -f "$POOL_NAME" 2>/dev/null || true
  fi

  # Remove sparse files and test directory
  rm -rf "$TEST_DIR"

  # Remove mount root
  rm -rf "$MOUNT_ROOT"

  info "Test infrastructure cleaned up."
}

trap cleanup_test_infra EXIT

#------------------------------------------------------------------------------
# Create sparse file vdevs and pool
#------------------------------------------------------------------------------
create_pool() {
  info "Creating sparse file vdevs..."

  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"

  local vdev
  for vdev in "${VDEV_FILES[@]}"; do
    truncate -s 1G "$vdev"
  done

  info "Creating RAIDZ1 pool '${POOL_NAME}'..."
  zpool create -f -m "$MOUNT_ROOT" "$POOL_NAME" raidz1 "${VDEV_FILES[@]}"

  # Create a minimal directory structure for chroot
  mkdir -p "${MOUNT_ROOT}/dev"
  mkdir -p "${MOUNT_ROOT}/proc"
  mkdir -p "${MOUNT_ROOT}/sys"
  mkdir -p "${MOUNT_ROOT}/bin"
  mkdir -p "${MOUNT_ROOT}/usr/bin"
  mkdir -p "${MOUNT_ROOT}/tmp"

  success "Pool '${POOL_NAME}' created and mounted at ${MOUNT_ROOT}."
}

#------------------------------------------------------------------------------
# Test 1: Traditional approach (mount --rbind + chroot)
#------------------------------------------------------------------------------
test_traditional() {
  info "=== TEST 1: Traditional approach (mount --rbind / --make-rslave) ==="

  create_pool

  info "Performing bind mounts..."
  mount --rbind /dev  "${MOUNT_ROOT}/dev"  && mount --make-rslave "${MOUNT_ROOT}/dev"
  mount --rbind /proc "${MOUNT_ROOT}/proc" && mount --make-rslave "${MOUNT_ROOT}/proc"
  mount --rbind /sys  "${MOUNT_ROOT}/sys"  && mount --make-rslave "${MOUNT_ROOT}/sys"

  info "Simulating chroot work (touch a file)..."
  # We don't need a real chroot, just the bind mounts to demonstrate the issue
  touch "${MOUNT_ROOT}/tmp/traditional-test"

  info "Cleaning up bind mounts..."
  umount -R "${MOUNT_ROOT}/sys"  2>/dev/null || warn "Failed to umount /sys"
  umount -R "${MOUNT_ROOT}/proc" 2>/dev/null || warn "Failed to umount /proc"
  umount -R "${MOUNT_ROOT}/dev"  2>/dev/null || warn "Failed to umount /dev"

  info "Attempting zpool export..."
  if zpool export "$POOL_NAME" 2>&1; then
    success "Traditional: zpool export succeeded (pool was not busy)."
    return 0
  else
    warn "Traditional: zpool export FAILED - pool is busy (expected behavior)."
    # Force destroy for cleanup
    zpool destroy -f "$POOL_NAME" 2>/dev/null || true
    return 1
  fi
}

#------------------------------------------------------------------------------
# Test 2: Namespace approach (unshare --mount --fork --pid --kill-child)
#------------------------------------------------------------------------------
test_namespace() {
  info "=== TEST 2: Namespace approach (unshare --mount --fork --pid --kill-child) ==="

  create_pool

  info "Creating namespace wrapper script..."
  cat > "${MOUNT_ROOT}/tmp/ns-wrapper.sh" <<'WRAPPER_EOF'
#!/bin/bash
set -euo pipefail

MOUNT_ROOT="$1"

# Bind mounts inside the namespace - these vanish when namespace exits
mount --rbind /dev  "${MOUNT_ROOT}/dev"  && mount --make-rslave "${MOUNT_ROOT}/dev"
mount -t proc proc  "${MOUNT_ROOT}/proc"
mount --rbind /sys  "${MOUNT_ROOT}/sys"  && mount --make-rslave "${MOUNT_ROOT}/sys"

# Simulate chroot work
touch "${MOUNT_ROOT}/tmp/namespace-test"

echo "[INFO] Namespace wrapper complete - mounts will auto-clean on exit."
WRAPPER_EOF
  chmod +x "${MOUNT_ROOT}/tmp/ns-wrapper.sh"

  info "Running chroot operations inside mount namespace..."
  unshare --mount --fork --pid --kill-child -- \
    bash "${MOUNT_ROOT}/tmp/ns-wrapper.sh" "$MOUNT_ROOT"

  info "Namespace exited. Attempting zpool export..."
  if zpool export "$POOL_NAME" 2>&1; then
    success "Namespace: zpool export succeeded - clean cleanup!"
    return 0
  else
    error "Namespace: zpool export FAILED - this is unexpected."
    zpool destroy -f "$POOL_NAME" 2>/dev/null || true
    return 1
  fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
  info "ZFS Namespace Cleanup Test"
  info "========================="
  echo

  preflight_checks

  local traditional_result=0
  local namespace_result=0

  # Run traditional test
  test_traditional || traditional_result=$?
  echo

  # Run namespace test
  test_namespace || namespace_result=$?
  echo

  # Summary
  info "=== RESULTS ==="
  if [[ $traditional_result -ne 0 ]]; then
    warn "Traditional: FAILED to export (busy mounts) - demonstrates the problem"
  else
    info "Traditional: Exported OK (mount refs may not have leaked in this env)"
  fi

  if [[ $namespace_result -eq 0 ]]; then
    success "Namespace: Exported OK - namespace isolation works!"
  else
    error "Namespace: FAILED - unexpected"
  fi

  echo
  if [[ $namespace_result -eq 0 ]]; then
    success "Test confirms namespace isolation provides clean cleanup."
    return 0
  else
    fatal "Namespace test failed unexpectedly."
  fi
}

main "$@"
