# disorderfs: multi-user mode broken under user namespaces (Nix sandbox)

## Context

We're using disorderfs as the build directory for Nix sandboxed builds
(`--multi-user=yes --sort-dirents=yes`) to get reproducible directory
ordering.  This fails with `EACCES` under the Nix Linux sandbox, which
uses `CLONE_NEWUSER` + `CLONE_NEWNS` + `pivot_root` + `setgroups deny`.

The same setup works fine with a plain directory or tmpfs as the build
dir, so the issue is specific to FUSE/disorderfs.

## Issue 1: `default_permissions` rejects accesses from child user namespaces

### Problem

disorderfs unconditionally enables the `default_permissions` FUSE mount
option.  With this option, the kernel performs a DAC check using
`capable_wrt_inode_uidgid()`, which requires `CAP_DAC_OVERRIDE` in the
FUSE mount's user namespace (i.e. the initial user namespace).
Processes inside a child user namespace such as a Nix sandbox
lack capabilities in the host namespace, so `default_permissions`
rejects their requests with `EACCES` before they ever reach the
disorderfs daemon.

### Reproducer

1. Mount disorderfs with `--multi-user=yes`.
2. From a child user namespace (e.g. `unshare -U -r`), try to access
   a file on the mount that the mapped UID should have permission to
   access.
3. Observe `EACCES` even though the file permissions allow the access.

### Expected behavior

In multi-user mode, the daemon already enforces access control by
dropping privileges to the FUSE caller (`Guard::drop_privileges`)
before touching the backing filesystem.  `default_permissions` is
redundant here and actively harmful for user-namespace callers.

It should be possible to skip `default_permissions` in multi-user mode,
since the daemon's own privilege-dropping provides the authorization.
Note that this interacts with the known FUSE permission-caching bug
([libfuse#15](https://github.com/libfuse/libfuse/issues/15)):
without `default_permissions`, cached permission results may be reused
across users while the inode is cached.  A correct fix likely also
needs to disable attribute caching or implement an `.access` handler.

## Issue 2: `drop_privileges` causes `EACCES` on intermediate directories

### Problem

Even after `default_permissions` is removed (so FUSE requests reach the
daemon), `Guard::drop_privileges()` causes a second failure.  The
daemon does `seteuid(caller_uid)` and then accesses the backing
filesystem using a path-concatenated string (`root + path`).  This
re-traverses every path component under the caller's credentials.

In the Nix sandbox setup, the directory hierarchy on the backing FS
looks like:

```
src/                     (root:root 0700)   <- disorderfs source dir
src/nix-XXXXXX/          (root:root 0700)   <- created by Nix daemon
src/nix-XXXXXX/build/    (builder:nixbld 0700)  <- chowned to build user
```

The FUSE mount exposes `build/` into the sandbox as `/build`.  When
the builder writes `/build/env-vars`, the FUSE path is
`/nix-XXXXXX/build/env-vars`.  After `seteuid(builder_uid)`, traversing
the root-owned `src/` and `nix-XXXXXX/` directories fails because the
build user has no search permission on them.

This is arguably a general problem: `drop_privileges` assumes the FUSE
caller can traverse all ancestor directories on the backing filesystem,
which is not necessarily true when the backing dir hierarchy has
restrictive permissions.

### Expected behavior

The daemon should be able to resolve ancestor path components as root
(since the kernel FUSE module already authorized the request) and only
apply the caller's credentials for the final operation on the target
itself.

We implemented a downstream fix using fd-relative syscalls (`openat`,
`mkdirat`, `fstatat`, etc.): walk ancestor components as root to obtain
an `O_PATH` fd, then drop privileges and operate relative to the pinned
fd.  This preserves per-file authorization while bypassing ancestor
search permission checks.
