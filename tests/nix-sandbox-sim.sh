#!/usr/bin/env bash
# Simulate the exact Nix sandbox setup sequence for testing.
# This reproduces what linux-derivation-builder.cc does.
#
# Usage: nix-sandbox-sim.sh <fuse_mount> <chroot_dir> <host_uid> <host_gid>
#
# Optional environment variables:
#   SIM_SECCOMP=1    — set PR_SET_NO_NEW_PRIVS and load a seccomp filter
#                      (SCMP_ACT_ALLOW default, like Nix's setupSeccomp)
#   SIM_NEWPID=1     — add CLONE_NEWPID to the namespace flags
#   SIM_EXECVE=1     — use execve(bash) for the write instead of Python open()
#   SIM_ALLNS=1      — add CLONE_NEWNET + CLONE_NEWIPC + CLONE_NEWUTS
#   SIM_HELPER=1     — use Nix's helper process architecture:
#                      fork helper → helper drops groups → helper forks child
#
# Nix's actual sequence for single-UID auto-allocate builds:
# 1. Daemon (root) creates tmpDir, chowns to host_uid
# 2. clone(CLONE_NEWUSER|CLONE_NEWNS|...) - child inherits host uid 0
# 3. Parent writes uid_map: "1000 <host_uid> 1", setgroups=deny
#    -> child appears as uid 65534 (overflow) because host uid 0 is unmapped
#    -> but child has full capabilities in the new user namespace
# 4. Child does: MS_PRIVATE, bind-mounts, pivot_root, chroot
# 5. Child calls setgid(100), setuid(1000) -> becomes host_uid:host_gid
# 6. Builder runs as uid 1000 (mapped to host_uid), writes files

set -euo pipefail

FUSE_MOUNT="$1"
CHROOT_DIR="$2"
HOST_UID="$3"
HOST_GID="$4"

SANDBOX_UID=1000
SANDBOX_GID=100

exec python3 - "$FUSE_MOUNT" "$CHROOT_DIR" "$HOST_UID" "$HOST_GID" "$SANDBOX_UID" "$SANDBOX_GID" \
    "${SIM_SECCOMP:-0}" "${SIM_NEWPID:-0}" "${SIM_EXECVE:-0}" \
    "${SIM_ALLNS:-0}" "${SIM_HELPER:-0}" << 'PYTHON_SCRIPT'
import ctypes
import ctypes.util
import os
import sys

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

CLONE_NEWUSER = 0x10000000
CLONE_NEWNS   = 0x00020000
CLONE_NEWPID  = 0x20000000
CLONE_NEWNET  = 0x40000000
CLONE_NEWIPC  = 0x08000000
CLONE_NEWUTS  = 0x04000000

MS_BIND    = 4096
MS_REC     = 16384
MS_PRIVATE = 1 << 18
MNT_DETACH = 2

SYS_pivot_root = 155  # x86_64

PR_SET_NO_NEW_PRIVS = 38

fuse_mount = sys.argv[1]
chroot_dir = sys.argv[2]
host_uid = int(sys.argv[3])
host_gid = int(sys.argv[4])
sandbox_uid = int(sys.argv[5])
sandbox_gid = int(sys.argv[6])
opt_seccomp = sys.argv[7] == "1"
opt_newpid = sys.argv[8] == "1"
opt_execve = sys.argv[9] == "1"
opt_allns = sys.argv[10] == "1"
opt_helper = sys.argv[11] == "1"

# Try to load libseccomp if seccomp is requested
libseccomp = None
if opt_seccomp:
    try:
        libseccomp = ctypes.CDLL("libseccomp.so.2", use_errno=True)
    except OSError:
        path = ctypes.util.find_library("seccomp")
        if path:
            libseccomp = ctypes.CDLL(path, use_errno=True)
    if libseccomp is None:
        print("WARNING: libseccomp not found, skipping seccomp setup", file=sys.stderr)
        opt_seccomp = False

def do_mount(source, target, fstype, flags, data):
    src = source.encode() if source else None
    tgt = target.encode()
    fst = fstype.encode() if fstype else None
    dat = data.encode() if data else None
    ret = libc.mount(src, tgt, fst, flags, dat)
    if ret != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, f"mount({source}, {target}, {fstype}, {flags}): {os.strerror(errno)}")

def umount2(target, flags):
    ret = libc.umount2(target.encode(), flags)
    if ret != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, f"umount2({target}): {os.strerror(errno)}")

def pivot_root(new_root, put_old):
    ret = libc.syscall(SYS_pivot_root, new_root.encode(), put_old.encode())
    if ret != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, f"pivot_root({new_root}, {put_old}): {os.strerror(errno)}")

def write_uid_map(child_pid):
    """Write uid_map/gid_map for the child process."""
    proc = f"/proc/{child_pid}"
    with open(f"{proc}/setgroups", "w") as f:
        f.write("deny")
    with open(f"{proc}/uid_map", "w") as f:
        f.write(f"{sandbox_uid} {host_uid} 1\n")
    with open(f"{proc}/gid_map", "w") as f:
        f.write(f"{sandbox_gid} {host_gid} 1\n")
    print(f"uid_map {sandbox_uid}->{host_uid}, gid_map {sandbox_gid}->{host_gid}, setgroups=deny", file=sys.stderr)

def sandbox_child_main():
    """Run the sandbox setup and build test. Called after uid_map is written."""
    try:
        # After uid_map is written: host uid 0 is NOT in the map
        # (map is "1000 <host_uid> 1"), so we appear as uid 65534 (overflow).
        # But we have full capabilities in the new user namespace.
        print(f"after uid_map: uid={os.getuid()} gid={os.getgid()} (expected 65534 - overflow, has caps)", file=sys.stderr)

        # Step 2: Make all filesystems private (like Nix line 607)
        do_mount(None, "/", None, MS_PRIVATE | MS_REC, None)

        # Step 3: Bind-mount chrootRootDir to itself (like Nix line 612)
        do_mount(chroot_dir, chroot_dir, None, MS_BIND, None)

        # Step 4: Bind-mount the FUSE mount into chroot/build (like Nix line 709)
        do_mount(fuse_mount, os.path.join(chroot_dir, "build"), None, MS_BIND | MS_REC, None)

        # Bind essentials
        for d in ["/bin", "/usr", "/lib", "/lib64", "/run", "/nix/store"]:
            target = os.path.join(chroot_dir, d.lstrip("/"))
            if os.path.isdir(d) and os.path.isdir(target):
                try:
                    do_mount(d, target, None, MS_BIND | MS_REC, None)
                except OSError:
                    pass

        # Bind /dev/null
        dev_null = os.path.join(chroot_dir, "dev", "null")
        os.makedirs(os.path.dirname(dev_null), exist_ok=True)
        if not os.path.exists(dev_null):
            open(dev_null, "w").close()
        try:
            do_mount("/dev/null", dev_null, None, MS_BIND, None)
        except OSError:
            pass

        # Mount proc
        proc_dir = os.path.join(chroot_dir, "proc")
        os.makedirs(proc_dir, exist_ok=True)
        try:
            do_mount("none", proc_dir, "proc", 0, None)
        except OSError as e:
            print(f"proc mount: {e} (non-fatal)", file=sys.stderr)

        # Step 5: Second unshare (like Nix line 771)
        libc.unshare(CLONE_NEWNS)

        # Step 6: pivot_root (like Nix lines 781-797)
        os.chdir(chroot_dir)

        old_root = os.path.join(chroot_dir, "old-root")
        os.makedirs(old_root, exist_ok=True)

        pivot_root(".", "old-root")
        os.chroot(".")

        try:
            umount2("old-root", MNT_DETACH)
        except OSError:
            pass
        try:
            os.rmdir("old-root")
        except OSError:
            pass

        # Step 7: setupSeccomp (like Nix line 799, before runChild)
        if opt_seccomp and libseccomp is not None:
            SCMP_ACT_ALLOW = 0x7fff0000
            ctx = libseccomp.seccomp_init(SCMP_ACT_ALLOW)
            if ctx:
                ret = libseccomp.seccomp_load(ctx)
                if ret != 0:
                    print(f"seccomp_load failed: {ret}", file=sys.stderr)
                else:
                    print("seccomp: loaded SCMP_ACT_ALLOW filter", file=sys.stderr)
                libseccomp.seccomp_release(ctx)
            else:
                print("seccomp_init failed", file=sys.stderr)

            ret = libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
            if ret != 0:
                errno = ctypes.get_errno()
                print(f"prctl(NO_NEW_PRIVS) failed: {os.strerror(errno)}", file=sys.stderr)
            else:
                print("prctl: NO_NEW_PRIVS set", file=sys.stderr)

        # Step 8: chdir to /build
        os.chdir("/build")

        # Step 9: umask
        os.umask(0o022)

        # Step 10: setUser() - drop to sandbox UID/GID
        try:
            os.setgid(sandbox_gid)
            os.setuid(sandbox_uid)
            print(f"after setUser: uid={os.getuid()} gid={os.getgid()}", file=sys.stderr)
        except OSError as e:
            print(f"setUser failed: {e}", file=sys.stderr)
            print(f"  uid_map maps {sandbox_uid} -> host {host_uid}", file=sys.stderr)
            print(f"  gid_map maps {sandbox_gid} -> host {host_gid}", file=sys.stderr)

        # Step 11: Try to write /build/test-env-vars
        if opt_execve:
            os.execve("/bin/sh", ["/bin/sh", "-c",
                'if echo "test=value" > /build/test-env-vars 2>/dev/null; then '
                'echo "RESULT:PASS"; else echo "RESULT:FAIL"; fi'],
                {"PATH": "/bin:/usr/bin", "HOME": "/build",
                 "NIX_BUILD_TOP": "/build"})
        else:
            try:
                fd = os.open("/build/test-env-vars", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o666)
                os.write(fd, b"test=value\n")
                os.close(fd)
                os.write(1, b"RESULT:PASS\n")
            except OSError as e:
                os.write(1, b"RESULT:FAIL\n")
                print(f"write /build/test-env-vars failed: {e}", file=sys.stderr)
                try:
                    st = os.stat("/build")
                    print(f"  /build: uid={st.st_uid} gid={st.st_gid} mode={oct(st.st_mode)}", file=sys.stderr)
                except Exception as e2:
                    print(f"  stat /build failed: {e2}", file=sys.stderr)

    except Exception as e:
        os.write(1, b"RESULT:FAIL\n")
        print(f"sandbox setup error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)

    os._exit(0)


# ============================================================================
# Main: fork/exec architecture
# ============================================================================

# Synchronization pipes: parent-to-child and child-to-parent
p2c_r, p2c_w = os.pipe()
c2p_r, c2p_w = os.pipe()

def fork_child_and_setup():
    """Fork the sandbox child, set up uid_map, signal it to proceed.
    Returns child_pid to the caller (parent)."""
    child_pid = os.fork()
    if child_pid == 0:
        # === SANDBOX CHILD ===
        os.close(p2c_w)
        os.close(c2p_r)

        # Step 1: unshare namespaces
        clone_flags = CLONE_NEWUSER | CLONE_NEWNS
        if opt_newpid:
            clone_flags |= CLONE_NEWPID
        if opt_allns:
            clone_flags |= CLONE_NEWNET | CLONE_NEWIPC | CLONE_NEWUTS
        print(f"unshare flags: {clone_flags:#x}", file=sys.stderr)
        ret = libc.unshare(clone_flags)
        if ret != 0:
            errno = ctypes.get_errno()
            print(f"unshare failed: {os.strerror(errno)}", file=sys.stderr)
            os._exit(1)

        # Signal parent/helper: unshare done
        os.write(c2p_w, b"1")
        os.close(c2p_w)

        # Wait for uid_map setup
        data = os.read(p2c_r, 1)
        os.close(p2c_r)
        if data != b"1":
            print("parent signaled failure", file=sys.stderr)
            os._exit(1)

        # Continue with sandbox setup
        sandbox_child_main()
        # Never returns

    # === PARENT/HELPER continues here ===
    os.close(p2c_r)
    os.close(c2p_w)

    # Wait for child's unshare
    data = os.read(c2p_r, 1)
    os.close(c2p_r)
    if data != b"1":
        print("child unshare failed", file=sys.stderr)
        os.write(p2c_w, b"0")
        os.close(p2c_w)
        return child_pid

    # Write uid_map/gid_map
    try:
        write_uid_map(child_pid)
    except Exception as e:
        print(f"failed to set up namespace: {e}", file=sys.stderr)
        os.write(p2c_w, b"0")
        os.close(p2c_w)
        return child_pid

    # Signal child to proceed
    os.write(p2c_w, b"1")
    os.close(p2c_w)
    return child_pid


if opt_helper:
    # Nix's helper architecture:
    #   daemon forks helper → helper drops groups → helper forks sandbox child
    #   → helper writes uid_map → helper exits → daemon waits for child
    helper_pid = os.fork()
    if helper_pid == 0:
        # === HELPER PROCESS ===
        os.setgroups([])
        print(f"helper: dropped supplementary groups, pid={os.getpid()}", file=sys.stderr)
        child_pid = fork_child_and_setup()
        # Helper exits after setting up uid_map
        os._exit(0)
    else:
        # === ORIGINAL PROCESS ===
        os.close(p2c_r)
        os.close(p2c_w)
        os.close(c2p_r)
        os.close(c2p_w)
        # Wait for helper
        _, hstatus = os.waitpid(helper_pid, 0)
        if os.WIFEXITED(hstatus) and os.WEXITSTATUS(hstatus) != 0:
            print(f"helper exited with status {os.WEXITSTATUS(hstatus)}", file=sys.stderr)
            print("RESULT:FAIL")
            sys.exit(1)
        # Wait for grandchild (sandbox child, orphaned when helper exited)
        try:
            _, status = os.waitpid(-1, 0)
            if os.WIFEXITED(status) and os.WEXITSTATUS(status) != 0:
                print(f"sandbox child exited with status {os.WEXITSTATUS(status)}", file=sys.stderr)
        except ChildProcessError:
            pass
        sys.exit(0)
else:
    # Simple mode: direct fork
    child_pid = fork_child_and_setup()
    # Wait for child
    _, status = os.waitpid(child_pid, 0)
    if os.WIFEXITED(status) and os.WEXITSTATUS(status) != 0:
        print(f"child exited with status {os.WEXITSTATUS(status)}", file=sys.stderr)
PYTHON_SCRIPT
