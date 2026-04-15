#!/usr/bin/env bash
# Test bed for identifying which part of the Nix sandbox breaks disorderfs.
#
# Tests go from simple disorderfs usage to progressively adding sandbox
# features until we reproduce the failure. Each test is isolated and
# prints PASS/FAIL with diagnostics.
#
# Must be run as root (sudo).
# Usage: sudo ./tests/run-tests.sh [test_number...]
#   Run all tests:    sudo ./tests/run-tests.sh
#   Run specific:     sudo ./tests/run-tests.sh 01 05 10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_SANDBOX_SIM="${NIX_SANDBOX_SIM:-$SCRIPT_DIR/nix-sandbox-sim.sh}"
WORK_DIR="/tmp/nix-buildon-tests"
PASSED=0
FAILED=0
SKIPPED=0
RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup_all() {
    for mnt in "$WORK_DIR"/*/mnt "$WORK_DIR"/*/disorderfs-mnt; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount -l "$mnt" 2>/dev/null || true
        fi
    done
    rm -rf "$WORK_DIR"
}

setup_test() {
    local name="$1"
    local dir="$WORK_DIR/$name"
    mkdir -p "$dir"/{src,mnt}
    echo "$dir"
}

cleanup_test() {
    local dir="$1"
    for mnt in "$dir/mnt" "$dir/disorderfs-mnt"; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount -l "$mnt" 2>/dev/null || true
        fi
    done
    rm -rf "$dir"
}

pass() {
    local name="$1"
    shift
    echo -e "  ${GREEN}PASS${NC} $name${*:+ ($*)}"
    PASSED=$((PASSED + 1))
    RESULTS+=("PASS $name")
}

fail() {
    local name="$1"
    shift
    echo -e "  ${RED}FAIL${NC} $name${*:+ ($*)}"
    FAILED=$((FAILED + 1))
    RESULTS+=("FAIL $name")
}

skip() {
    local name="$1"
    shift
    echo -e "  ${YELLOW}SKIP${NC} $name${*:+ ($*)}"
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("SKIP $name")
}

run_test() {
    local num="$1"
    local name="$2"
    local func="$3"
    local label="${num}: ${name}"

    echo -e "${BLUE}--- Test ${label}${NC}"
    if "$func" "$label"; then
        true
    fi
    echo ""
}

should_run() {
    local num="$1"
    if [[ ${#FILTER[@]} -eq 0 ]]; then
        return 0
    fi
    for f in "${FILTER[@]}"; do
        if [[ "$f" == "$num" ]]; then
            return 0
        fi
    done
    return 1
}

# ============================================================================
# Test 01: Basic disorderfs mount (no multi-user)
# Baseline: can we mount and write files on disorderfs at all?
# ============================================================================
test_01_basic_disorderfs() {
    local label="$1"
    local dir
    dir=$(setup_test "01")
    trap "cleanup_test '$dir'" RETURN

    disorderfs --sort-dirents=yes "$dir/src" "$dir/mnt" 2>/dev/null

    if touch "$dir/mnt/testfile" 2>/dev/null; then
        pass "$label" "touch works on disorderfs"
    else
        fail "$label" "touch failed on basic disorderfs mount"
    fi
}

# ============================================================================
# Test 02: disorderfs with --multi-user=yes (as root)
# Does multi-user mode work for root?
# ============================================================================
test_02_multiuser_root() {
    local label="$1"
    local dir
    dir=$(setup_test "02")
    trap "cleanup_test '$dir'" RETURN

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    if touch "$dir/mnt/testfile" 2>/dev/null; then
        pass "$label" "root can write to multi-user disorderfs"
    else
        fail "$label" "root cannot write to multi-user disorderfs"
    fi
}

# ============================================================================
# Test 03: disorderfs multi-user, write as different UID (no namespaces)
# Simulate a non-root user writing to the FUSE mount.
# ============================================================================
test_03_multiuser_other_uid() {
    local label="$1"
    local dir
    dir=$(setup_test "03")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    # Write as nobody (uid=65534) via python seteuid
    local result
    result=$(python3 -c "
import os
os.setgroups([])
os.setegid(65534)
os.seteuid(65534)
fd = os.open('$dir/mnt/testfile', os.O_CREAT | os.O_WRONLY, 0o666)
os.close(fd)
print('PASS')
" 2>&1) || true

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "non-root can write via disorderfs multi-user"
    else
        fail "$label" "$result"
    fi
}

# ============================================================================
# Test 04: disorderfs multi-user with group perms + ACLs
# Does group-based access work on the backing dir?
# ============================================================================
test_04_multiuser_group_write() {
    local label="$1"
    local dir
    dir=$(setup_test "04")
    trap "cleanup_test '$dir'" RETURN

    chown root:nixbld "$dir/src"
    chmod 2775 "$dir/src"
    setfacl -m g:nixbld:rwx "$dir/src"
    setfacl -d -m g:nixbld:rwx "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown root:nixbld "$dir/mnt"
    chmod 2775 "$dir/mnt"
    setfacl -m g:nixbld:rwx "$dir/mnt"
    setfacl -d -m g:nixbld:rwx "$dir/mnt"

    if touch "$dir/mnt/testfile" 2>/dev/null; then
        pass "$label" "root can write with group perms set up"
    else
        fail "$label" "root cannot write even with full perms"
    fi
}

# ============================================================================
# Test 05: Mount namespace only (unshare -m)
# Does disorderfs survive a bind-mount into a new mount namespace?
# ============================================================================
test_05_mount_namespace() {
    local label="$1"
    local dir
    dir=$(setup_test "05")
    trap "cleanup_test '$dir'" RETURN

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown root:nixbld "$dir/mnt"
    chmod 2775 "$dir/mnt"

    local result
    result=$(unshare --mount -- bash -c '
        target=$(mktemp -d)
        mount --bind "'"$dir/mnt"'" "$target"
        if touch "$target/testfile"; then
            echo "PASS"
        else
            echo "FAIL: errno=$?"
        fi
        umount "$target"
        rmdir "$target"
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "bind-mount in mount namespace works"
    else
        fail "$label" "$result"
    fi
}

# ============================================================================
# Test 06: Mount namespace + pivot_root
# Does disorderfs survive pivot_root?
# ============================================================================
test_06_pivot_root() {
    local label="$1"
    local dir
    dir=$(setup_test "06")
    trap "cleanup_test '$dir'" RETURN

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown root:nixbld "$dir/mnt"
    chmod 2775 "$dir/mnt"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,lib,lib64,usr,nix/store}

    local result
    result=$(unshare --mount --pid --fork -- bash -c '
        chrootdir="'"$chroot_dir"'"
        srcmnt="'"$dir/mnt"'"

        mount --make-rprivate /
        mount --bind "$chrootdir" "$chrootdir"
        mount --bind "$srcmnt" "$chrootdir/build"

        # Bind mount essentials
        mount --bind /bin "$chrootdir/bin" 2>/dev/null || true
        mount --bind /usr "$chrootdir/usr" 2>/dev/null || true
        for d in /lib /lib64; do
            [ -d "$d" ] && mount --bind "$d" "$chrootdir/$d" 2>/dev/null || true
        done
        mount --bind /nix/store "$chrootdir/nix/store"
        mount -t proc proc "$chrootdir/proc"
        # Bind /dev/null so touch and other tools work after pivot_root
        touch "$chrootdir/dev/null"
        mount --bind /dev/null "$chrootdir/dev/null"

        cd "$chrootdir"
        mkdir -p old-root
        pivot_root . old-root
        cd /
        umount -l /old-root 2>/dev/null || true

        if touch /build/testfile; then
            echo "PASS"
        else
            echo "FAIL: errno=$?"
        fi
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "disorderfs survives pivot_root"
    else
        fail "$label" "$result"
    fi
}

# ============================================================================
# Test 07: User namespace only (no mount namespace)
# Does a user namespace UID remap break disorderfs access?
# ============================================================================
test_07_user_namespace() {
    local label="$1"
    local dir
    dir=$(setup_test "07")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    # --map-root-user maps virtual 0 -> real caller (root here)
    local result
    result=$(unshare --user --map-root-user -- bash -c '
        echo "id=$(id)"
        if touch "'"$dir/mnt"'/testfile"; then
            echo "PASS"
        else
            echo "FAIL: errno=$?"
        fi
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "user namespace UID remap works"
    else
        fail "$label" "$(echo "$result" | tail -1)"
    fi
}

# ============================================================================
# Test 08: User namespace with setgroups deny
# This matches what Nix does: denies setgroups in the user namespace.
# --map-root-user implies setgroups=deny for single-UID mappings.
# ============================================================================
test_08_userns_setgroups_deny() {
    local label="$1"
    local dir
    dir=$(setup_test "08")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    # --map-root-user: maps uid 0->caller, writes setgroups=deny, single-UID
    local result
    result=$(unshare --user --map-root-user -- bash -c '
        echo "id=$(id)"
        echo "groups=$(cat /proc/self/status | grep Groups)"
        echo "setgroups=$(cat /proc/self/setgroups 2>/dev/null || echo N/A)"
        if touch "'"$dir/mnt"'/testfile"; then
            echo "PASS"
        else
            echo "FAIL: errno=$?"
        fi
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "user namespace with setgroups deny works"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 09: User namespace + mount namespace (no pivot_root)
# Combine user + mount namespace like Nix does, but without pivot_root.
# ============================================================================
test_09_userns_plus_mountns() {
    local label="$1"
    local dir
    dir=$(setup_test "09")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    local result
    result=$(unshare --user --mount --map-root-user -- bash -c '
        target=$(mktemp -d)
        mount --bind "'"$dir/mnt"'" "$target"
        echo "bind-mount: $?"
        echo "id=$(id)"
        if touch "$target/testfile"; then
            echo "PASS"
        else
            echo "FAIL: errno=$?"
        fi
        umount "$target" 2>/dev/null
        rmdir "$target" 2>/dev/null
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "userns + mountns works"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 10: User namespace + mount namespace + pivot_root
# Full namespace sandwich like Nix, writing as remapped UID.
# ============================================================================
test_10_full_ns_pivot() {
    local label="$1"
    local dir
    dir=$(setup_test "10")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,nix/store}

    local result
    result=$(unshare --user --mount --pid --fork --map-root-user -- bash -c '
        chrootdir="'"$chroot_dir"'"
        srcmnt="'"$dir/mnt"'"

        mount --make-rprivate /
        mount --bind "$chrootdir" "$chrootdir"
        mount --bind "$srcmnt" "$chrootdir/build"

        mount --bind /bin "$chrootdir/bin" 2>/dev/null || true
        mount --bind /usr "$chrootdir/usr" 2>/dev/null || true
        for d in /lib /lib64; do
            [ -d "$d" ] && mount --bind "$d" "$chrootdir/$d" 2>/dev/null || true
        done
        mount --bind /nix/store "$chrootdir/nix/store"
        mount -t proc proc "$chrootdir/proc"
        touch "$chrootdir/dev/null"
        mount --bind /dev/null "$chrootdir/dev/null"

        cd "$chrootdir"
        mkdir -p old-root
        pivot_root . old-root
        cd /
        umount -l /old-root 2>/dev/null || true

        echo "id=$(id)"
        if touch /build/testfile; then
            echo "PASS"
        else
            echo "FAIL: cannot write as userns-root"
        fi
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "full ns + pivot_root works (as userns root)"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 11: Write to disorderfs as auto-allocate UID (host-side, no namespace)
# Tests whether the high auto-allocate UID can write through disorderfs
# when the backing dir is owned by that UID (owner-based access).
# ============================================================================
test_11_nix_uid_mapping() {
    local label="$1"
    local dir
    dir=$(setup_test "11")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    # Use python to seteuid to the host UID (like disorderfs Guard does)
    local result
    result=$(python3 -c "
import os
os.setgroups([])
os.setegid($host_gid)
os.seteuid($host_uid)
fd = os.open('$dir/mnt/testfile', os.O_CREAT | os.O_WRONLY, 0o666)
os.close(fd)
print('PASS')
" 2>&1) || true

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "host UID ${host_uid} can write to disorderfs"
    else
        fail "$label" "$result"
    fi
}

# ============================================================================
# Test 12: Simulate disorderfs drop_privileges with empty groups
# This directly tests the hypothesis: does drop_privileges with an empty
# supplementary group list cause EACCES on a group-writable backing dir?
# ============================================================================
test_12_empty_groups_backing_dir() {
    local label="$1"
    local dir
    dir=$(setup_test "12")
    trap "cleanup_test '$dir'" RETURN

    chown root:nixbld "$dir/src"
    chmod 2775 "$dir/src"
    setfacl -m g:nixbld:rwx "$dir/src"

    local test_uid=872415232

    local result
    result=$(python3 -c "
import os
os.setgroups([])
os.setegid(30000)  # nixbld GID
os.seteuid($test_uid)
fd = os.open('$dir/src/testfile', os.O_CREAT | os.O_WRONLY, 0o666)
os.close(fd)
print('PASS')
" 2>&1) || true

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "UID with GID=nixbld but no supplementary groups can write"
    else
        fail "$label" "$result"
        echo "  -> This confirms group membership via primary GID is sufficient (or not)"
    fi
}

# ============================================================================
# Test 13: disorderfs with chown to auto-allocate UID (owner-based access)
# Test the exact ownership model Nix uses: tmpDir is chowned to buildUser UID.
# ============================================================================
test_13_owner_access() {
    local label="$1"
    local dir
    dir=$(setup_test "13")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt" 2>/dev/null || true
    chmod 0700 "$dir/mnt"

    local result
    result=$(python3 -c "
import os
os.setgroups([])
os.setegid($host_gid)
os.seteuid($host_uid)
fd = os.open('$dir/mnt/testfile', os.O_CREAT | os.O_WRONLY, 0o666)
os.close(fd)
print('PASS')
" 2>&1) || true

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "owner-based access through disorderfs works"
    else
        fail "$label" "$result"
    fi
}

# ============================================================================
# Test 14: Does FUSE survive a bind-mount inside a user namespace?
# Dir owned by the mapped uid (root).
# ============================================================================
test_14_userns_bindmount_fuse() {
    local label="$1"
    local dir
    dir=$(setup_test "14")
    trap "cleanup_test '$dir'" RETURN

    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 0700 "$dir/mnt"

    local result
    result=$(unshare --user --mount --map-root-user -- bash -c '
        target=$(mktemp -d)
        if mount --bind "'"$dir/mnt"'" "$target" 2>&1; then
            echo "bind-mount: ok"
        else
            echo "FAIL: cannot bind-mount"
            exit 1
        fi

        if touch "$target/testfile"; then
            echo "PASS"
        else
            echo "FAIL: cannot write"
            ls -la "$target/" 2>&1 || true
        fi

        umount "$target" 2>/dev/null || true
        rmdir "$target" 2>/dev/null || true
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "userns + bind-mount + disorderfs works"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 15: Compare with tmpfs (control test)
# Run the same namespace setup but with a regular tmpfs instead of disorderfs.
# If this passes but disorderfs fails, the issue is FUSE-specific.
# ============================================================================
test_15_tmpfs_control() {
    local label="$1"
    local dir
    dir=$(setup_test "15")
    trap "cleanup_test '$dir'" RETURN

    mount -t tmpfs tmpfs "$dir/mnt"
    chmod 1777 "$dir/mnt"

    local result
    result=$(unshare --user --mount --map-root-user -- bash -c '
        target=$(mktemp -d)
        mount --bind "'"$dir/mnt"'" "$target"
        if touch "$target/testfile"; then
            echo "PASS"
        else
            echo "FAIL: cannot write to tmpfs through userns"
        fi
        umount "$target" 2>/dev/null || true
        rmdir "$target" 2>/dev/null || true
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "tmpfs through userns works (control)"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 16: disorderfs control -- same test as 15 but with disorderfs
# Direct comparison to test 15.
# ============================================================================
test_16_disorderfs_vs_tmpfs() {
    local label="$1"
    local dir
    dir=$(setup_test "16")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    local result
    result=$(unshare --user --mount --map-root-user -- bash -c '
        target=$(mktemp -d)
        mount --bind "'"$dir/mnt"'" "$target"
        echo "id=$(id)"
        if touch "$target/testfile"; then
            echo "PASS"
        else
            echo "FAIL: cannot write to disorderfs through userns"
            ls -la "$target/" 2>&1 || true
        fi
        umount "$target" 2>/dev/null || true
        rmdir "$target" 2>/dev/null || true
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "disorderfs through userns works"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 17: disorderfs through userns, then setuid to non-root
# This matches Nix's setUser(): after entering the userns as root,
# drop to UID 1000 before writing.
# ============================================================================
test_17_userns_setuid() {
    local label="$1"
    local dir
    dir=$(setup_test "17")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    local result
    result=$(unshare --user --mount --map-root-user -- bash -c '
        target=$(mktemp -d)
        mount --bind "'"$dir/mnt"'" "$target"

        if touch "$target/as-root"; then
            echo "write-as-userns-root: ok"
        else
            echo "write-as-userns-root: FAIL"
        fi

        python3 -c "
import os
try:
    fd = os.open(\"$target/as-root-py\", os.O_CREAT | os.O_WRONLY, 0o666)
    os.close(fd)
    print(\"PASS\")
except Exception as e:
    print(f\"FAIL: {e}\")
"
    ' 2>&1)

    if echo "$result" | grep -q "^PASS$"; then
        pass "$label" "write after userns setup works"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 18: Full Nix-like sandbox simulation
# Reproduce the exact sequence Nix uses:
# 1. Create tmpDir on disorderfs, chown to build UID
# 2. clone(CLONE_NEWUSER|CLONE_NEWNS|CLONE_NEWPID)
# 3. Set uid_map/gid_map with setgroups=deny
# 4. MS_PRIVATE, bind-mount, pivot_root
# 5. setuid/setgid to sandbox uid
# 6. Write /build/env-vars
# ============================================================================
test_18_full_nix_simulation() {
    local label="$1"
    local dir
    dir=$(setup_test "18")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$("$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "full Nix sandbox simulation passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 19: Same as test 18 but with tmpfs (control)
# ============================================================================
test_19_full_nix_simulation_tmpfs() {
    local label="$1"
    local dir
    dir=$(setup_test "19")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    mount -t tmpfs tmpfs "$dir/mnt"

    chown "${host_uid}:${host_gid}" "$dir/mnt" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$("$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "full Nix sandbox simulation with tmpfs passes (control)"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 20: Actual nix build with disorderfs (integration test)
# Run a real nix build with sandbox=true using the disorderfs-backed build-dir.
# ============================================================================
test_20_real_nix_build() {
    local label="$1"
    # Nix checks all parent dirs are not world-writable.
    # /tmp and /var/tmp are 1777, so use /run (0755).
    local dir="/run/nix-buildon-test-20"
    rm -rf "$dir"
    mkdir -p "$dir"/{src,mnt}
    chmod 0700 "$dir"
    trap "umount -l '$dir/mnt' 2>/dev/null; rm -rf '$dir'" RETURN

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null
    local fuse_pid
    fuse_pid=$(pgrep -f "disorderfs.*$dir/mnt" | head -1)

    chmod 0700 "$dir/mnt"

    # Verify mount options
    echo "    mount options: $(grep "$dir/mnt" /proc/mounts)"
    echo "    disorderfs pid: $fuse_pid"

    # Strace the FUSE daemon to see if requests reach it
    local fuse_strace="$dir/fuse-strace.log"
    strace -f -e trace=openat,open,mkdir,setresuid,setresgid,setresuid32,setresgid32,setgroups,setgroups32 \
        -o "$fuse_strace" -p "$fuse_pid" &
    local strace_fuse_pid=$!
    sleep 0.2

    # shellcheck disable=SC2016
    local build_result drv_path strace_log="$dir/strace.log"
    drv_path=$(nix-instantiate --option build-dir "$dir/mnt" \
        -E '(import <nixpkgs> {}).runCommand "disorderfs-test-'"$(date +%s)"'" {} "echo ok > \$out"' 2>/dev/null) || {
        fail "$label" "nix-instantiate failed"
        return
    }
    if build_result=$(strace -f -e trace=openat,mkdir,chdir,chown,fchown,mount,pivot_root,write,execve,clone,clone3,setuid,setgid,setresuid,setresgid \
        -o "$strace_log" \
        nix-store -r "$drv_path" --option build-dir "$dir/mnt" --option sandbox true 2>&1); then
        pass "$label" "real nix build with disorderfs + sandbox works!"
    else
        fail "$label" "nix build failed"
        echo "$build_result" | grep -v '^evaluating' | tail -5 | while IFS= read -r line; do
            echo "    $line"
        done
        # Find the child PID (the one that does chdir("/build"))
        local child_pid
        child_pid=$(grep 'chdir("/build")' "$strace_log" | head -1 | cut -d' ' -f1)
        echo "    sandbox child pid: $child_pid"

        echo "    --- ALL env-vars accesses (any PID) ---"
        grep 'env-vars' "$strace_log" | while IFS= read -r line; do
            echo "    $line"
        done

        # Find the subshell PID (cloned from sandbox child)
        local subshell_pid
        subshell_pid=$(grep 'env-vars' "$strace_log" | head -1 | cut -d' ' -f1)
        if [[ -n "$subshell_pid" && "$subshell_pid" != "$child_pid" ]]; then
            echo "    subshell pid: $subshell_pid"
            echo "    --- subshell strace (all calls) ---"
            grep "^$subshell_pid " "$strace_log" | head -20 | while IFS= read -r line; do
                echo "    $line"
            done
        else
            echo "    --- sandbox child full sequence around env-vars ---"
            grep "^$child_pid " "$strace_log" | grep -A999 'chdir("/build")' | head -40 | while IFS= read -r line; do
                echo "    $line"
            done
        fi
        echo "    --- disorderfs daemon strace ---"
        kill "$strace_fuse_pid" 2>/dev/null; wait "$strace_fuse_pid" 2>/dev/null || true
        grep -v 'SIGSTOP\|PTRACE\|restart_syscall\|strace:' "$fuse_strace" 2>/dev/null | tail -30 | while IFS= read -r line; do
            echo "    $line"
        done
    fi
}

# ============================================================================
# Test 21: Bare FUSE access from user namespace (diagnostic)
# Minimal test: can ANY process in a child user namespace touch a file
# on a FUSE mount? No bind-mount, no pivot_root, no Nix — just
# unshare --user + direct access. Isolates the kernel-level FUSE
# userns check (fuse_allow_current_process / current_in_userns).
# ============================================================================
test_21_fuse_userns_diagnostic() {
    local label="$1"
    local dir
    dir=$(setup_test "21")
    trap "cleanup_test '$dir'" RETURN

    chmod 1777 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chmod 1777 "$dir/mnt"

    echo "    mount options: $(grep "$dir/mnt" /proc/mounts)"
    echo "    kernel: $(uname -r)"

    # Test A: direct access from user namespace (no mount namespace)
    local resultA
    resultA=$(unshare --user --map-root-user -- touch "$dir/mnt/from-userns" 2>&1) && resultA="PASS" || resultA="FAIL: $resultA"
    echo "    A) userns direct access: $resultA"

    # Test B: same but with mount namespace too
    local resultB
    resultB=$(unshare --user --mount --map-root-user -- touch "$dir/mnt/from-userns-mountns" 2>&1) && resultB="PASS" || resultB="FAIL: $resultB"
    echo "    B) userns+mountns direct access: $resultB"

    # Test C: from a child user namespace created by clone (like Nix)
    local resultC
    resultC=$(python3 -c "
import os, ctypes, ctypes.util, sys
libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
CLONE_NEWUSER = 0x10000000

p2c_r, p2c_w = os.pipe()
c2p_r, c2p_w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(p2c_w); os.close(c2p_r)
    libc.unshare(CLONE_NEWUSER)
    os.write(c2p_w, b'1'); os.close(c2p_w)
    os.read(p2c_r, 1); os.close(p2c_r)
    try:
        fd = os.open('$dir/mnt/from-clone-userns', os.O_CREAT|os.O_WRONLY, 0o666)
        os.close(fd)
        os.write(1, b'PASS\n')
    except OSError as e:
        os.write(1, f'FAIL: {e}\n'.encode())
    os._exit(0)
else:
    os.close(p2c_r); os.close(c2p_w)
    os.read(c2p_r, 1); os.close(c2p_r)
    with open(f'/proc/{pid}/setgroups','w') as f: f.write('deny')
    with open(f'/proc/{pid}/uid_map','w') as f: f.write('0 0 1\n')
    with open(f'/proc/{pid}/gid_map','w') as f: f.write('0 0 1\n')
    os.write(p2c_w, b'1'); os.close(p2c_w)
    os.waitpid(pid, 0)
" 2>&1)
    resultC=$(echo "$resultC" | tail -1)
    echo "    C) clone(CLONE_NEWUSER) + uid_map 0->0: $resultC"

    # Test D: same but with uid_map that does NOT include host uid 0
    local resultD
    resultD=$(python3 -c "
import os, ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
CLONE_NEWUSER = 0x10000000

p2c_r, p2c_w = os.pipe()
c2p_r, c2p_w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(p2c_w); os.close(c2p_r)
    libc.unshare(CLONE_NEWUSER)
    os.write(c2p_w, b'1'); os.close(c2p_w)
    os.read(p2c_r, 1); os.close(p2c_r)
    try:
        fd = os.open('$dir/mnt/from-clone-unmapped', os.O_CREAT|os.O_WRONLY, 0o666)
        os.close(fd)
        os.write(1, b'PASS\n')
    except OSError as e:
        os.write(1, f'FAIL: {e}\n'.encode())
    os._exit(0)
else:
    os.close(p2c_r); os.close(c2p_w)
    os.read(c2p_r, 1); os.close(c2p_r)
    with open(f'/proc/{pid}/setgroups','w') as f: f.write('deny')
    with open(f'/proc/{pid}/uid_map','w') as f: f.write('1000 872415232 1\n')
    with open(f'/proc/{pid}/gid_map','w') as f: f.write('100 30000 1\n')
    os.write(p2c_w, b'1'); os.close(p2c_w)
    os.waitpid(pid, 0)
" 2>&1)
    resultD=$(echo "$resultD" | tail -1)
    echo "    D) clone(CLONE_NEWUSER) + uid_map 1000->872415232 (host 0 unmapped): $resultD"

    if [[ "$resultA" == "PASS" && "$resultB" == "PASS" && "$resultC" == "PASS" && "$resultD" == "PASS" ]]; then
        pass "$label" "all FUSE userns access variants work"
    elif [[ "$resultA" == "PASS" ]]; then
        fail "$label" "some variants fail (see above)"
    else
        fail "$label" "basic FUSE userns access blocked by kernel"
    fi
}

# ============================================================================
# Test 22: Nix simulation + seccomp (NO_NEW_PRIVS + SCMP_ACT_ALLOW filter)
# Adds PR_SET_NO_NEW_PRIVS and a seccomp filter with SCMP_ACT_ALLOW default
# (same as Nix's setupSeccomp). Tests if seccomp blocks FUSE access.
# ============================================================================
test_22_simulation_seccomp() {
    local label="$1"
    local dir
    dir=$(setup_test "22")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_SECCOMP=1 "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + seccomp passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 23: Nix simulation + CLONE_NEWPID (PID namespace)
# Adds CLONE_NEWPID to the namespace flags. Tests if PID namespace isolation
# breaks FUSE access (e.g., by making /proc/<pid> inaccessible).
# ============================================================================
test_23_simulation_newpid() {
    local label="$1"
    local dir
    dir=$(setup_test "23")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_NEWPID=1 "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + CLONE_NEWPID passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 24: Nix simulation + execve(bash) for the write
# Instead of Python's os.open(), use execve(/bin/sh) to write the file,
# matching how the real Nix builder (bash running stdenv/setup) does it.
# ============================================================================
test_24_simulation_execve() {
    local label="$1"
    local dir
    dir=$(setup_test "24")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_EXECVE=1 "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + execve(bash) passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 25: Full Nix simulation with ALL extras (seccomp + NEWPID + execve)
# Combines all features that differ between test 18 and the real Nix build.
# If this fails but 22-24 pass individually, it's a combination effect.
# ============================================================================
test_25_simulation_all() {
    local label="$1"
    local dir
    dir=$(setup_test "25")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_SECCOMP=1 SIM_NEWPID=1 SIM_EXECVE=1 \
        "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + seccomp + NEWPID + execve passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 26: Simulation + all extra namespaces (NET + IPC + UTS)
# Nix uses CLONE_NEWNET, CLONE_NEWIPC, CLONE_NEWUTS in addition to
# CLONE_NEWUSER and CLONE_NEWNS. Tests if these break FUSE access.
# ============================================================================
test_26_simulation_allns() {
    local label="$1"
    local dir
    dir=$(setup_test "26")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_ALLNS=1 "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + all namespaces passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 27: Simulation + helper process architecture
# Uses Nix's fork-helper-then-fork-child pattern:
#   fork helper → helper drops supplementary groups → helper forks child
#   → helper writes uid_map → helper exits
# ============================================================================
test_27_simulation_helper() {
    local label="$1"
    local dir
    dir=$(setup_test "27")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_HELPER=1 "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + helper process passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 28: FULL simulation — all features combined
# Combines ALL remaining differences: seccomp + NEWPID + execve +
# all namespaces + helper process. If this passes too, the difference
# must be in the daemon/client architecture or mount namespace origin.
# ============================================================================
test_28_simulation_everything() {
    local label="$1"
    local dir
    dir=$(setup_test "28")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chown "${host_uid}:${host_gid}" "$dir/src" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }
    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    chown "${host_uid}:${host_gid}" "$dir/mnt"
    chmod 0700 "$dir/mnt"

    touch "$dir/mnt/env-vars"
    chown "${host_uid}:${host_gid}" "$dir/mnt/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_SECCOMP=1 SIM_NEWPID=1 SIM_EXECVE=1 SIM_ALLNS=1 SIM_HELPER=1 \
        "$NIX_SANDBOX_SIM" "$dir/mnt" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation + ALL features passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 29: Simulation with nested subdirectory (like real Nix)
# Nix doesn't bind-mount the FUSE root — it creates mnt/nix-XXXXXX/build/
# inside the FUSE mount and bind-mounts THAT subdirectory. This tests if
# the subdirectory path makes a difference.
# ============================================================================
test_29_simulation_nested_subdir() {
    local label="$1"
    local dir
    dir=$(setup_test "29")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    # Simulate what the daemon does: createTempDir + setBuildTmpDir
    # Creates mnt/nix-XXXXXX/ (topTmpDir) then mnt/nix-XXXXXX/build/ (tmpDir)
    local top_tmp_dir
    top_tmp_dir=$(mktemp -d "$dir/mnt/nix-XXXXXX")
    chmod 0700 "$top_tmp_dir"
    local build_dir="$top_tmp_dir/build"
    mkdir -p "$build_dir"
    chmod 0700 "$build_dir"

    # chownToBuilder: daemon chowns tmpDir to the build user
    chown "${host_uid}:${host_gid}" "$build_dir" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }

    # daemon writes env-vars into tmpDir
    touch "$build_dir/env-vars"
    chown "${host_uid}:${host_gid}" "$build_dir/env-vars"

    echo "    build_dir: $build_dir"
    echo "    ls: $(ls -la "$build_dir/" 2>&1)"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    # Pass the subdirectory path, NOT the FUSE root
    local result
    result=$(SIM_SECCOMP=1 SIM_NEWPID=1 SIM_EXECVE=1 SIM_ALLNS=1 SIM_HELPER=1 \
        "$NIX_SANDBOX_SIM" "$build_dir" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "nested subdir simulation passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 30: Simulation invoked from /run (not /tmp)
# Nix rejects build-dir under world-writable dirs. Real builds use /run.
# Tests if the path location matters.
# ============================================================================
test_30_simulation_run_path() {
    local label="$1"
    local dir="/run/nix-buildon-test-30"
    rm -rf "$dir"
    mkdir -p "$dir"/{src,mnt}
    chmod 0700 "$dir"
    trap "umount -l '$dir/mnt' 2>/dev/null; rm -rf '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    # Mimic Nix: create nested tmpDir inside FUSE mount
    local top_tmp_dir
    top_tmp_dir=$(mktemp -d "$dir/mnt/nix-XXXXXX")
    chmod 0700 "$top_tmp_dir"
    local build_dir="$top_tmp_dir/build"
    mkdir -p "$build_dir"
    chmod 0700 "$build_dir"
    chown "${host_uid}:${host_gid}" "$build_dir" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }

    touch "$build_dir/env-vars"
    chown "${host_uid}:${host_gid}" "$build_dir/env-vars"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_SECCOMP=1 SIM_NEWPID=1 SIM_EXECVE=1 SIM_ALLNS=1 SIM_HELPER=1 \
        "$NIX_SANDBOX_SIM" "$build_dir" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "simulation under /run passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 31: Real nix build — DIAGNOSTIC (re-check with patched disorderfs)
# Like test 20 but with enhanced diagnostics:
# - Checks if request reaches disorderfs daemon
# - Shows /proc/mounts for default_permissions
# - Straces both sides
# - Also tests nix-store --option build-dir with sandbox=false as control
# ============================================================================
test_31_real_nix_diagnostic() {
    local label="$1"
    local dir="/run/nix-buildon-test-31"
    rm -rf "$dir"
    mkdir -p "$dir"/{src,mnt}
    chmod 0700 "$dir"
    trap "umount -l '$dir/mnt' 2>/dev/null; rm -rf '$dir'" RETURN

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    # Verify default_permissions is NOT set
    local mount_opts
    mount_opts=$(grep "$dir/mnt" /proc/mounts)
    echo "    mount: $mount_opts"
    if echo "$mount_opts" | grep -q "default_permissions"; then
        echo "    WARNING: default_permissions is still set!"
    else
        echo "    OK: default_permissions removed"
    fi

    chmod 0700 "$dir/mnt"

    # Strace the FUSE daemon
    local fuse_pid
    fuse_pid=$(pgrep -f "disorderfs.*$dir/mnt" | head -1)
    echo "    disorderfs pid: $fuse_pid"

    local fuse_strace="$dir/fuse-strace.log"
    strace -f -e trace=openat,mkdir,setresuid,setresgid,setgroups \
        -o "$fuse_strace" -p "$fuse_pid" &
    local strace_fuse_pid=$!
    sleep 0.2

    # Test sandbox=true
    echo "    --- test: sandbox=true ---"
    # shellcheck disable=SC2016
    local drv_path
    drv_path=$(nix-instantiate --option build-dir "$dir/mnt" \
        -E 'derivation { name = "disorderfs-test-'"$(date +%s)"'"; system = builtins.currentSystem; builder = "/bin/sh"; args = ["-c" "echo ok > \$out"]; }' 2>/dev/null) || {
        fail "$label" "nix-instantiate failed"
        return
    }
    local strace_log="$dir/strace.log"
    local build_result
    if build_result=$(strace -f -e trace=openat,mkdir,chdir,mount,pivot_root,write,execve,clone,clone3,setuid,setgid,setresuid,setresgid \
        -o "$strace_log" \
        nix-store -r "$drv_path" --option build-dir "$dir/mnt" --option sandbox true 2>&1); then
        pass "$label" "real nix build with patched disorderfs works!"
    else
        fail "$label" "sandbox=true still fails"
        echo "$build_result" | tail -3 | while IFS= read -r line; do
            echo "    $line"
        done

        # Check strace for the failing openat
        echo "    --- env-vars access attempts ---"
        grep 'env-vars' "$strace_log" 2>/dev/null | while IFS= read -r line; do
            echo "    $line"
        done

        echo "    --- did request reach disorderfs daemon? ---"
        kill "$strace_fuse_pid" 2>/dev/null; wait "$strace_fuse_pid" 2>/dev/null || true
        local daemon_calls
        daemon_calls=$(grep -v 'SIGSTOP\|PTRACE\|restart_syscall\|strace:' "$fuse_strace" 2>/dev/null | grep -c '.' || echo 0)
        if [[ "$daemon_calls" -gt 0 ]]; then
            echo "    YES: $daemon_calls syscalls reached daemon after strace attach"
            grep -v 'SIGSTOP\|PTRACE\|restart_syscall\|strace:' "$fuse_strace" 2>/dev/null | tail -20 | while IFS= read -r line; do
                echo "    $line"
            done
        else
            echo "    NO: zero syscalls reached disorderfs daemon — kernel blocked it"
        fi

        # Show what the sandbox child did
        local child_pid
        child_pid=$(grep 'chdir("/build")' "$strace_log" 2>/dev/null | head -1 | cut -d' ' -f1)
        if [[ -n "$child_pid" ]]; then
            echo "    --- sandbox child ($child_pid) around the failure ---"
            grep "^$child_pid " "$strace_log" 2>/dev/null | grep -A5 -B5 'env-vars\|EACCES' | head -20 | while IFS= read -r line; do
                echo "    $line"
            done
        fi
    fi
}

# ============================================================================
# Test 32: Nested subdir + traversable backing dir
# Same as test 29 but make the backing dir (src/) world-searchable (0711)
# so disorderfs's drop_privileges can traverse the path on the real FS.
# If this passes, the root cause is backing-dir traversal after seteuid.
# ============================================================================
test_32_nested_traversable_backing() {
    local label="$1"
    local dir
    dir=$(setup_test "32")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    # KEY DIFFERENCE: backing dir is world-searchable
    chmod 0711 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    # Simulate Nix's createTempDir + setBuildTmpDir
    local top_tmp_dir
    top_tmp_dir=$(mktemp -d "$dir/mnt/nix-XXXXXX")
    chmod 0711 "$top_tmp_dir"  # also make this traversable
    local build_dir="$top_tmp_dir/build"
    mkdir -p "$build_dir"
    chmod 0700 "$build_dir"
    chown "${host_uid}:${host_gid}" "$build_dir" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }

    touch "$build_dir/env-vars"
    chown "${host_uid}:${host_gid}" "$build_dir/env-vars"

    echo "    backing dir perms: $(stat -c '%a %U:%G' "$dir/src")"
    echo "    top_tmp backing: $(stat -c '%a %U:%G' "$dir/src"/nix-*)"
    echo "    build backing: $(stat -c '%a %U:%G' "$dir/src"/nix-*/build)"

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_SECCOMP=1 SIM_NEWPID=1 SIM_EXECVE=1 SIM_ALLNS=1 SIM_HELPER=1 \
        "$NIX_SANDBOX_SIM" "$build_dir" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "nested subdir + traversable backing passes"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Test 33: Nested subdir + strace disorderfs daemon
# Same as test 29 but strace the disorderfs daemon to verify whether
# requests are actually reaching it (vs being blocked by the kernel).
# ============================================================================
test_33_nested_strace_daemon() {
    local label="$1"
    local dir
    dir=$(setup_test "33")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chmod 0700 "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    local fuse_pid
    fuse_pid=$(pgrep -f "disorderfs.*$dir/mnt" | head -1)

    local top_tmp_dir
    top_tmp_dir=$(mktemp -d "$dir/mnt/nix-XXXXXX")
    chmod 0700 "$top_tmp_dir"
    local build_dir="$top_tmp_dir/build"
    mkdir -p "$build_dir"
    chmod 0700 "$build_dir"
    chown "${host_uid}:${host_gid}" "$build_dir" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }

    touch "$build_dir/env-vars"
    chown "${host_uid}:${host_gid}" "$build_dir/env-vars"

    # Strace the daemon
    local fuse_strace="$dir/fuse-strace.log"
    strace -f -e trace=openat,open,mkdir,setresuid,setresgid,setgroups \
        -o "$fuse_strace" -p "$fuse_pid" &
    local strace_fuse_pid=$!
    sleep 0.2

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$("$NIX_SANDBOX_SIM" "$build_dir" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    # Kill strace
    kill "$strace_fuse_pid" 2>/dev/null; wait "$strace_fuse_pid" 2>/dev/null || true

    local daemon_calls
    daemon_calls=$(grep -v 'SIGSTOP\|PTRACE\|restart_syscall\|strace:' "$fuse_strace" 2>/dev/null | grep -c '.' || echo 0)

    echo "    disorderfs daemon syscalls during test: $daemon_calls"
    if [[ "$daemon_calls" -gt 0 ]]; then
        echo "    -> request DID reach daemon (backing FS issue)"
        grep -v 'SIGSTOP\|PTRACE\|restart_syscall\|strace:' "$fuse_strace" 2>/dev/null | tail -15 | while IFS= read -r line; do
            echo "    $line"
        done
    else
        echo "    -> request did NOT reach daemon (kernel FUSE check)"
    fi

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "nested subdir + daemon strace"
    else
        fail "$label" "request $([ "$daemon_calls" -gt 0 ] && echo 'reached' || echo 'blocked before') daemon"
    fi
}

# ============================================================================
# Test 34: Nested subdir + default ACL o::x on backing dir (Option D fix)
# Verifies the bulidon.sh fix: setfacl -d -m o::x on the backing dir
# makes new subdirectories world-searchable, fixing drop_privileges traversal.
# ============================================================================
test_34_nested_default_acl_fix() {
    local label="$1"
    local dir
    dir=$(setup_test "34")
    trap "cleanup_test '$dir'" RETURN

    local host_uid=872415232
    local host_gid=30000

    chmod 0700 "$dir/src"
    # THE FIX: default ACL gives other::x on new dirs
    setfacl -d -m o::x "$dir/src"

    disorderfs --sort-dirents=yes --multi-user=yes "$dir/src" "$dir/mnt" 2>/dev/null

    # Simulate Nix: daemon creates nix-XXXXXX/ as root:root 0700
    local top_tmp_dir
    top_tmp_dir=$(mktemp -d "$dir/mnt/nix-XXXXXX")
    chmod 0700 "$top_tmp_dir"
    local build_dir="$top_tmp_dir/build"
    mkdir -p "$build_dir"
    chmod 0700 "$build_dir"
    chown "${host_uid}:${host_gid}" "$build_dir" 2>/dev/null || {
        skip "$label" "cannot chown to UID ${host_uid}"
        return
    }

    touch "$build_dir/env-vars"
    chown "${host_uid}:${host_gid}" "$build_dir/env-vars"

    # Verify ACL inherited on backing dir
    echo "    backing src ACL: $(getfacl -p "$dir/src" 2>/dev/null | grep default | tr '\n' ' ')"
    local backing_subdir
    backing_subdir=$(find "$dir/src" -maxdepth 1 -name 'nix-*' -type d | head -1)
    if [[ -n "$backing_subdir" ]]; then
        echo "    backing nix-XXX perms: $(stat -c '%a' "$backing_subdir") acl: $(getfacl -p "$backing_subdir" 2>/dev/null | grep other | head -1)"
    fi

    local chroot_dir="$dir/chroot"
    mkdir -p "$chroot_dir"/{build,old-root,proc,dev,bin,usr,lib,lib64,tmp,run,etc,nix/store}

    cat > "$chroot_dir/etc/passwd" << 'EOF'
root:x:0:0:Nix build user:/build:/noshell
nixbld:x:1000:100:Nix build user:/build:/noshell
nobody:x:65534:65534:Nobody:/:/noshell
EOF
    cat > "$chroot_dir/etc/group" << 'EOF'
root:x:0:
nixbld:!:100:
nogroup:x:65534:
EOF

    local result
    result=$(SIM_SECCOMP=1 SIM_NEWPID=1 SIM_EXECVE=1 SIM_ALLNS=1 SIM_HELPER=1 \
        "$NIX_SANDBOX_SIM" "$build_dir" "$chroot_dir" "$host_uid" "$host_gid" 2>&1)

    if echo "$result" | grep -q "^RESULT:PASS$"; then
        pass "$label" "default ACL o::x fix works"
    else
        fail "$label" "$(echo "$result" | tr '\n' ' ')"
    fi
}

# ============================================================================
# Main
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "This test suite must be run as root (sudo)."
    exit 1
fi

FILTER=("${@}")

cleanup_all
mkdir -p "$WORK_DIR"

echo -e "${BLUE}=== Nix Sandbox + disorderfs Test Suite ===${NC}"
echo ""

declare -A TESTS=(
    [01]="Basic disorderfs mount|test_01_basic_disorderfs"
    [02]="disorderfs --multi-user=yes as root|test_02_multiuser_root"
    [03]="disorderfs multi-user write as different UID|test_03_multiuser_other_uid"
    [04]="disorderfs multi-user with group perms|test_04_multiuser_group_write"
    [05]="Bind-mount in mount namespace|test_05_mount_namespace"
    [06]="Mount namespace + pivot_root|test_06_pivot_root"
    [07]="User namespace UID remap|test_07_user_namespace"
    [08]="User namespace with setgroups deny|test_08_userns_setgroups_deny"
    [09]="User namespace + mount namespace|test_09_userns_plus_mountns"
    [10]="Full namespace + pivot_root|test_10_full_ns_pivot"
    [11]="Nix auto-allocate UID mapping|test_11_nix_uid_mapping"
    [12]="Empty groups on backing dir|test_12_empty_groups_backing_dir"
    [13]="Owner-based access through disorderfs|test_13_owner_access"
    [14]="userns + bind-mount + FUSE|test_14_userns_bindmount_fuse"
    [15]="tmpfs through userns (control)|test_15_tmpfs_control"
    [16]="disorderfs through userns|test_16_disorderfs_vs_tmpfs"
    [17]="userns then setuid write|test_17_userns_setuid"
    [18]="Full Nix sandbox simulation (disorderfs)|test_18_full_nix_simulation"
    [19]="Full Nix sandbox simulation (tmpfs control)|test_19_full_nix_simulation_tmpfs"
    [20]="Real nix build with disorderfs|test_20_real_nix_build"
    [21]="FUSE userns diagnostic|test_21_fuse_userns_diagnostic"
    [22]="Simulation + seccomp (NO_NEW_PRIVS)|test_22_simulation_seccomp"
    [23]="Simulation + CLONE_NEWPID|test_23_simulation_newpid"
    [24]="Simulation + execve(bash)|test_24_simulation_execve"
    [25]="Simulation + ALL (seccomp+NEWPID+execve)|test_25_simulation_all"
    [26]="Simulation + all namespaces (NET+IPC+UTS)|test_26_simulation_allns"
    [27]="Simulation + helper process|test_27_simulation_helper"
    [28]="Simulation + EVERYTHING combined|test_28_simulation_everything"
    [29]="Simulation + nested subdir (like Nix)|test_29_simulation_nested_subdir"
    [30]="Simulation under /run + nested subdir|test_30_simulation_run_path"
    [31]="Real nix build diagnostic (patched)|test_31_real_nix_diagnostic"
    [32]="Nested subdir + traversable backing|test_32_nested_traversable_backing"
    [33]="Nested subdir + strace daemon|test_33_nested_strace_daemon"
    [34]="Nested subdir + default ACL fix|test_34_nested_default_acl_fix"
)

for num in $(echo "${!TESTS[@]}" | tr ' ' '\n' | sort); do
    if should_run "$num"; then
        IFS='|' read -r name func <<< "${TESTS[$num]}"
        run_test "$num" "$name" "$func"
    fi
done

echo -e "${BLUE}=== Summary ===${NC}"
echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
echo -e "  ${RED}Failed: ${FAILED}${NC}"
echo -e "  ${YELLOW}Skipped: ${SKIPPED}${NC}"
echo ""
for r in "${RESULTS[@]}"; do
    case "$r" in
        PASS*) echo -e "  ${GREEN}${r}${NC}" ;;
        FAIL*) echo -e "  ${RED}${r}${NC}" ;;
        SKIP*) echo -e "  ${YELLOW}${r}${NC}" ;;
    esac
done

cleanup_all

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
