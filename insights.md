nix code: ../nix
disorderfs code: ../disorderfs

Goal: use disorderfs as Nix build-dir for sandboxed builds.

Script works with btrfs; failure is specific to disorderfs.
--multi-user=yes is required for this setup, because Nix sandbox/daemon builds run as nixbld* users and accesses must be checked with the caller’s credentials, not the mounter’s.
Basic manual operations on the disorderfs mount work:
touch
mkdir
ln -s
mv
chmod
rm -rf
nix build succeeds with sandbox = false.
nix build fails with sandbox enabled.
Therefore the issue is specifically the interaction between Nix Linux sandboxing and disorderfs, not generic write access.
Nix is definitely using the configured disorderfs-backed build-dir.
Strace of the actual nix build process found the first real failure:
openat(..., "/build/env-vars", O_WRONLY|O_CREAT|O_TRUNC, 0666) = -1 EACCES
So the concrete failure is: inside the sandbox, writing /build/env-vars gets EACCES.
Earlier readlink(...)=EINVAL lines were noise, not the cause.
We tried improving permissions with:
chown root:nixbld
chmod 2775
default ACLs g:nixbld:rwx
That did not fix the sandboxed failure.
env-vars is NOT written by the Nix daemon — it's written by the
stdenv setup script (nixpkgs), which runs INSIDE the sandbox:
  export 2>/dev/null >| "$NIX_BUILD_TOP/env-vars"
(found in /nix/store/...-stdenv-linux/setup)

So the builder (bash running stdenv/setup as sandbox uid 1000,
mapped to host auto-alloc uid 872415232) tries to write to /build/
which is bind-mounted from the disorderfs FUSE mount.

=== ROOT CAUSE (two layers) ===

LAYER 1: FUSE default_permissions blocks user-namespace access.
With default_permissions enabled, the kernel FUSE module does a
DAC check using capable_wrt_inode_uidgid(), which verifies
CAP_DAC_OVERRIDE in the FUSE mount's user namespace (init_user_ns).
Processes in a child user namespace (Nix sandbox) lack caps in the
host namespace → EACCES. The request never reaches disorderfs.
FIX: Remove default_permissions in multi-user mode (patch in patches/).

LAYER 2: disorderfs backing-dir traversal after drop_privileges.
With default_permissions removed, FUSE requests DO reach the
disorderfs daemon. But then Guard::drop_privileges() fails:

  1. Nix daemon creates buildDir/nix-XXXXXX/ (root:root 0700)
     and buildDir/nix-XXXXXX/build/ (chowned to build user).
  2. Only build/ is chowned; parent dirs stay root:root 0700.
  3. disorderfs bind-mounts build/ into the sandbox as /build.
  4. Sandbox builder writes /build/env-vars.
  5. FUSE sends the request to disorderfs with FUSE path
     /nix-XXXXXX/build/env-vars (relative to mount root).
  6. Guard does seteuid(build_uid=872415232), then opens
     src/nix-XXXXXX/build/env-vars on the backing filesystem.
  7. Traversing src/ (root:root 0700) fails → EACCES.
  8. Guard restores seteuid(0).

Confirmed by test 33 strace of daemon:
  setresuid(-1, 872415232, -1) → backing FS access → EACCES
  setresuid(-1, 0, -1) → restore

And test 32: making backing dir + intermediates 0711 → PASSES.

The earlier conclusion that "FUSE kernel module rejects requests"
was correct for the ORIGINAL disorderfs (with default_permissions).
After the patch removes default_permissions, requests DO reach
the daemon, but fail on backing-dir traversal permissions.

=== FIX (applied) ===

Single disorderfs patch (patches/disorderfs-no-default-permissions-multi-user.patch)
with two changes for multi-user mode:

1. Remove default_permissions mount option.
2. Skip Guard::drop_privileges() (access backing FS as root).

Security model: FUSE kernel module enforces access control via
fuse_allow_current_process() which checks allow_other and verifies
the caller is in the same user namespace or a descendant. The
backing FS root dir should be restrictive (0700 root) to prevent
direct (non-FUSE) access.

Confirmed working: test 31 — real nix-store -r with sandbox=true
on a disorderfs-backed build-dir passes.
