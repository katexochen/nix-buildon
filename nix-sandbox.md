# Nix Linux Sandbox Internals

## 1. Overview

The Nix daemon sets up a sandboxed build environment for each derivation using Linux namespaces (PID, mount, network, IPC, UTS, user), bind mounts, `pivot_root`, seccomp BPF filters, and user namespace UID/GID remapping. The daemon (running as root) prepares the build directory and chroot structure, then forks a child process that enters the sandbox before executing the builder.

Source files:
- `src/libstore/unix/build/derivation-builder.cc` — base `DerivationBuilderImpl` class (daemon-side setup, child `runChild()`)
- `src/libstore/unix/build/chroot-derivation-builder.cc` — `ChrootDerivationBuilder` (chroot directory setup)
- `src/libstore/unix/build/linux-derivation-builder.cc` — `LinuxDerivationBuilder` and `ChrootLinuxDerivationBuilder` (Linux-specific: namespaces, seccomp, pivot_root)

## 2. Build Directory Setup (daemon process, pre-fork)

All of this runs in the daemon process (as root), **before** any fork/clone.

1. **`startBuild()`** in `derivation-builder.cc:737` creates the top-level temp directory:
   ```cpp
   topTmpDir = createTempDir(buildDir, "nix", 0700);  // line 761
   ```

2. **`setBuildTmpDir()`** is called at line 762. The `ChrootDerivationBuilder` override (`chroot-derivation-builder.cc:32`) creates a nested directory:
   ```cpp
   tmpDir = topTmpDir / "build";  // line 41
   createDir(tmpDir, 0700);       // line 42
   ```

3. **`chownToBuilder(tmpDirFd, tmpDir)`** at line 771 — changes ownership of `tmpDir` to the build user:
   ```cpp
   // derivation-builder.cc:1261-1266
   if (fchown(fd, buildUser->getUID(), buildUser->getGID()) == -1)
       throw SysError("cannot change ownership of file %1%", PathFmt(path));
   ```
   For multi-user builds, this sets ownership to e.g. `nixbld1` (UID ~30001, GID 30000).

4. **`initEnv()`** at line 829 calls **`writeBuilderFile()`** for extra files (e.g., `env-vars`):
   ```cpp
   // derivation-builder.cc:1269-1282
   AutoCloseFD fd = openFileEnsureBeneathNoSymlinks(
       tmpDirFd.get(), relPath, O_WRONLY | O_TRUNC | O_CREAT | O_CLOEXEC | O_EXCL, 0666);
   writeFile(fd.get(), contents);
   chownToBuilder(fd.get(), path);
   ```
   This runs as root in the daemon — NOT inside the sandbox.

5. **`pathsInChroot[tmpDirInSandbox()] = {.source = tmpDir}`** at `derivation-builder.cc:895` — registers `tmpDir` to be bind-mounted into the sandbox at the sandbox build dir path (default `/build`).

## 3. Child Process Creation (`startChild()` in `linux-derivation-builder.cc:389`)

A helper process is used to work around `clone()` being broken in multi-threaded programs:

1. **Drop supplementary groups** in the helper:
   ```cpp
   setgroups(0, 0)  // line 449
   ```

2. **`clone()`** with namespace flags (`linux-derivation-builder.cc:458`):
   ```cpp
   options.cloneFlags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWIPC | CLONE_NEWUTS | CLONE_PARENT | SIGCHLD;
   ```
   - Plus `CLONE_NEWNET` for sandboxed derivations (line 460)
   - Plus `CLONE_NEWUSER` if user namespaces are supported (line 462)

3. The child process calls `runChild()` (line 464), which eventually calls `enterChroot()`.

## 4. User Namespace UID/GID Mapping (parent writes after clone, lines 506–519)

After the child is created, the **parent** sets up the user namespace mappings by writing to `/proc/<pid>/`:

```cpp
uid_t hostUid = buildUser ? buildUser->getUID() : getuid();   // line 510, e.g. 30001
uid_t hostGid = buildUser ? buildUser->getGID() : getgid();   // line 511, e.g. 30000
```

- **uid_map** (line 514): `"1000 30001 1"` — sandbox UID 1000 maps to host UID 30001
- **setgroups** (line 517): written as `"deny"` for single-UID builds — **this prevents `setgroups()` inside the user namespace**
- **gid_map** (line 519): `"100 30000 1"` — sandbox GID 100 maps to host GID 30000

The sandbox UIDs are determined by `sandboxUid()` / `sandboxGid()` (lines 313–321):
```cpp
sandboxUid() = usingUserNamespace ? (single-uid ? 1000 : 0) : buildUser->getUID();
sandboxGid() = usingUserNamespace ? (single-uid ? 100  : 0) : ...;
```

`/etc/passwd` inside the sandbox (lines 529–536):
```
nixbld:x:1000:100:Nix build user:/build:/noshell
```

## 5. Sandbox Setup in Child (`enterChroot()` in `linux-derivation-builder.cc:567`)

The full setup sequence inside the cloned child process:

1. **Wait for parent** to finish user namespace setup (line 571):
   ```cpp
   if (readLine(userNamespaceSync.readSide.get()) != "1")
       throw Error("user namespace initialisation failed");
   ```

2. **Set up loopback interface** for sandboxed derivations (lines 579–588):
   ```cpp
   ifr.ifr_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
   ioctl(fd.get(), SIOCSIFFLAGS, &ifr);
   ```

3. **Set hostname** to `"localhost"` (line 593):
   ```cpp
   sethostname(hostname, sizeof(hostname));
   ```

4. **Make all subtrees private** (line 607):
   ```cpp
   mount(0, "/", 0, MS_PRIVATE | MS_REC, 0);
   ```
   This prevents mount propagation from the sandbox to the host.

5. **Bind-mount `chrootRootDir` to itself** (line 612):
   ```cpp
   mount(chrootRootDir.c_str(), chrootRootDir.c_str(), 0, MS_BIND, 0);
   ```
   Required for `pivot_root` to work (needs a different filesystem from `/`).

6. **Bind-mount and share the store dir** (lines 625–629):
   ```cpp
   mount(chrootStoreDir.c_str(), chrootStoreDir.c_str(), 0, MS_BIND, 0);
   mount(0, chrootStoreDir.c_str(), 0, MS_SHARED, 0);
   ```
   The shared subtree allows `addDependency()` to make new store paths appear in the sandbox later.

7. **Set up `/dev` entries** (lines 634–657):
   - Creates `/dev/shm`, `/dev/pts` directories
   - Bind-mounts: `/dev/full`, `/dev/null`, `/dev/random`, `/dev/tty`, `/dev/urandom`, `/dev/zero`
   - Optionally `/dev/kvm` if `kvm` is in system features
   - Symlinks: `/dev/fd` → `/proc/self/fd`, `/dev/stdin`, `/dev/stdout`, `/dev/stderr`

8. **Bind-mount all `pathsInChroot`** (lines 693–711), including `tmpDir → chrootRootDir/build`:
   ```cpp
   for (auto & i : pathsInChroot) {
       doBind(i.second.source, chrootRootDir / i.first.relative_path(), i.second.optional);
   }
   ```
   **`doBind()`** at line 210:
   ```cpp
   mount(source.c_str(), target.c_str(), "", MS_BIND | MS_REC, 0);
   ```
   **This is where a FUSE mount gets propagated into the sandbox** — the bind mount of a FUSE-backed directory creates a new mount entry referencing the same FUSE superblock.

9. **Mount `/proc`** (line 715):
   ```cpp
   mount("none", (chrootRootDir / "proc").c_str(), "proc", 0, 0);
   ```

10. **Mount `/dev/shm` tmpfs** (lines 727–735):
    ```cpp
    mount("none", (chrootRootDir / "dev" / "shm").c_str(), "tmpfs", 0, fmt("size=%s", ...));
    ```

11. **Mount `/dev/pts` devpts** (lines 741–754):
    ```cpp
    mount("none", (chrootRootDir / "dev" / "pts").c_str(), "devpts", 0, "newinstance,mode=0620");
    ```

12. **`unshare(CLONE_NEWNS)`** second time (line 771) — creates a sub-mount-namespace so that `pivot_root` doesn't hide the host store from `addDependency()`:
    ```cpp
    if (unshare(CLONE_NEWNS) == -1)
        throw SysError("unsharing mount namespace");
    ```

13. **`chdir(chrootRootDir)`** (line 781)

14. **`pivot_root(".", "real-root")`** (line 787) — swaps the root filesystem

15. **`chroot(".")`** (line 790)

16. **`umount2("real-root", MNT_DETACH)`** (line 793) — detaches the old root filesystem

17. **`setupSeccomp()` and `NO_NEW_PRIVS`** via `LinuxDerivationBuilder::enterChroot()` (line 799 → lines 246–275):
    ```cpp
    prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);  // line 254
    setupSeccomp(localSettings);               // line 257
    ```

## 6. Seccomp Filters (`setupSeccomp`, lines 40–137)

The seccomp filter uses **`SCMP_ACT_ALLOW`** as the default action — all syscalls are allowed unless explicitly denied.

### Denied syscalls

**setuid/setgid bit creation** → `EPERM` (lines 78–114):
- `chmod`, `fchmod`, `fchmodat`, `fchmodat2` with `S_ISUID` or `S_ISGID` bits set
- This prevents builders from creating setuid/setgid binaries

**Extended attributes** → `ENOTSUP` (lines 119–125):
- `getxattr`, `lgetxattr`, `fgetxattr`, `setxattr`, `lsetxattr`, `fsetxattr`
- EAs/ACLs are not representable in NAR serialisation

### NOT denied
- `setuid`, `setgid`, `setresuid`, `setresgid`, `setgroups` — these are NOT filtered by seccomp (they are controlled by the user namespace instead)

### Additional settings
- `SCMP_FLTATR_CTL_NNP` is set based on `allowNewPrivileges` config (line 127) — ties the seccomp filter to the `NO_NEW_PRIVS` bit

## 7. Builder Execution (`runChild`, lines 1284–1386)

Sequence after `enterChroot()` returns:

1. **`chdir(tmpDirInSandbox())`** — changes to `/build` (line 1322)

2. **Close extra FDs** — `unix::closeExtraFDs()` (line 1326)

3. **`umask(0022)`** — predictable umask (line 1334)

4. **`setUser()`** — the `ChrootLinuxDerivationBuilder` override (lines 802–813):
   ```cpp
   setgid(sandboxGid());  // setgid(100) inside user namespace
   setuid(sandboxUid());  // setuid(1000) inside user namespace
   ```
   This drops from root (UID 0 in the user namespace) to the sandbox user.

5. **Write `"\2\n"`** to signal successful setup (line 1341)

6. **`execve(builder)`** (line 1417):
   ```cpp
   execve(drv.builder.c_str(), stringsToCharPtrs(args).data(), stringsToCharPtrs(envStrs).data());
   ```

## 8. FUSE Interaction Analysis

This section documents the critical interaction when a FUSE filesystem (like disorderfs) is used as `build-dir`.

### How FUSE mounts propagate

- The daemon creates `tmpDir` on the FUSE mount and runs operations as root (pre-fork) — this works fine since the daemon runs as root
- `doBind(tmpDir, chrootRootDir/build, MS_BIND|MS_REC)` (line 709) propagates the FUSE mount into the sandbox — the bind mount creates a new mount entry referencing the same FUSE superblock
- The FUSE daemon (e.g., disorderfs) continues to run in the **host** mount/PID namespace
- After `pivot_root` + `umount2(MNT_DETACH)` (lines 787–793), the FUSE superblock reference is kept alive via the bind mount in the new root

### UID translation through user namespace

- Inside sandbox: builder runs as UID 1000 / GID 100
- The kernel translates through the uid_map: host sees UID 30001 / GID 30000
- The FUSE daemon (host) receives `fuse_get_context()->uid = 30001` (the host UID)

### The double permission check problem with disorderfs

With `--multi-user=yes` and `default_permissions`:

1. **Kernel FUSE check** (`default_permissions`): The kernel checks the FUSE-visible inode permissions using the calling process's credentials (translated to host UID 30001). The FUSE inode metadata is populated by disorderfs's `getattr` handler.

2. **disorderfs `Guard::Guard()`**: Calls `drop_privileges()` → `thread_seteuid(fuse_get_context()->uid)` = `thread_seteuid(30001)` → then does `open(root + path, O_CREAT, mode)` on the **real** (backing) filesystem as UID 30001.

3. **Real filesystem check**: The kernel checks if UID 30001 can write to the backing directory.

### Where it likely fails

The backing directory (`ROOTDIR`) is the source directory that disorderfs overlays. The `bulidon.sh` script sets up permissions with `chown root:nixbld` + `chmod 2775` + ACLs on the source and mount dirs. However:

- disorderfs's `Guard` restores root after each operation, but the backing directory permissions need to allow the nixbld UID
- The **`setgroups` "deny"** written to `/proc/<pid>/setgroups` in the user namespace mapping (`linux-derivation-builder.cc:517`) means the child process in the sandbox cannot use `setgroups()` — the kernel reports no supplementary groups for processes in this user namespace
- `fuse_getgroups()` in disorderfs retrieves groups from `/proc/<pid>/task/<tid>/status` — with `setgroups` denied in the userns, supplementary groups are empty
- So even though the backing directory has group `nixbld` ACLs, the `thread_setgroups()` in `drop_privileges()` gets an empty group list → the real filesystem check doesn't see the `nixbld` group membership

**Root cause: the `nixbld` group membership is lost because the user namespace denies `setgroups`, causing `fuse_getgroups()` to return an empty list, and disorderfs's `drop_privileges()` clears all supplementary groups before accessing the backing filesystem.**

The host UID 30001 can only access the backing directory via:
- Owner permissions (but owner is `root`, not `nixbld1`)
- Group permissions (but `nixbld` group membership is lost due to the userns `setgroups` deny)
- Other permissions (2775 gives `r-x` to others, not write)
- ACL entries (but the ACL check also requires group membership, which is missing)

This means the builder inside the sandbox cannot write to `/build` when it's backed by a disorderfs FUSE mount with `--multi-user=yes`, because the supplementary group information needed to pass the backing filesystem's permission checks is lost in the user namespace translation.
