# Nix Sandbox + disorderfs Test Suite

Systematic test bed to identify which part of the Nix Linux sandbox breaks
when using disorderfs as the build directory.

## Usage

```bash
# Run all tests (must be root)
sudo ./tests/run-tests.sh

# Run specific tests
sudo ./tests/run-tests.sh 01 05 16

# Run the full simulation tests
sudo ./tests/run-tests.sh 18 19 20
```

## Test Progression

Tests are ordered from simple to complex, progressively adding sandbox
features to isolate which one causes the failure. Each test is independent.

### Layer 1: Basic disorderfs (no namespaces)

| Test | Description | What it isolates |
|------|-------------|------------------|
| 01 | Basic disorderfs mount (no multi-user) | Can we mount and write at all? |
| 02 | disorderfs `--multi-user=yes` as root | Does multi-user mode work for root? |
| 03 | Multi-user, write as different UID | Does `allow_other` work? |
| 04 | Multi-user with group perms + ACLs | Does group-based access work? |

### Layer 2: Individual namespace features

| Test | Description | What it isolates |
|------|-------------|------------------|
| 05 | Bind-mount in mount namespace | Does FUSE survive `CLONE_NEWNS` + bind-mount? |
| 06 | Mount namespace + `pivot_root` | Does FUSE survive `pivot_root` + `umount2`? |
| 07 | User namespace UID remap | Does UID translation break FUSE? |
| 08 | User namespace with `setgroups deny` | Does `setgroups=deny` affect FUSE group checks? |

### Layer 3: Combined features

| Test | Description | What it isolates |
|------|-------------|------------------|
| 09 | User namespace + mount namespace | Combined userns + mountns |
| 10 | Full namespace + `pivot_root` | All namespace features together |
| 11 | Nix auto-allocate UID mapping | Does the actual host UID (872415232) work? |
| 12 | Empty groups on backing dir | Direct test of the group-loss hypothesis |
| 13 | Owner-based access through disorderfs | Does owner-based access (not group) work? |
| 14 | userns + bind-mount + FUSE | The exact FUSE-through-userns path |

### Layer 4: Comparative controls

| Test | Description | What it isolates |
|------|-------------|------------------|
| 15 | tmpfs through userns (control) | Same setup but tmpfs — if this passes, issue is FUSE-specific |
| 16 | disorderfs through userns | Direct comparison to test 15 |
| 17 | userns then setuid write | Tests Nix's `setUser()` drop |

### Layer 5: Full simulation & integration

| Test | Description | What it isolates |
|------|-------------|------------------|
| 18 | Full Nix sandbox simulation (disorderfs) | Reproduces the exact Nix daemon sequence |
| 19 | Full Nix sandbox simulation (tmpfs control) | Same as 18 but with tmpfs |
| 20 | Real `nix build` with disorderfs | Actual integration test |

## Interpreting Results

The expected outcome is that tests fail at some specific layer, revealing
which sandbox feature is incompatible with disorderfs:

- **Fails at Layer 1**: disorderfs itself is broken (unlikely given unsandboxed builds work)
- **Fails at Layer 2, test 05-06**: FUSE + mount namespace / `pivot_root` issue
- **Fails at Layer 2, test 07-08**: user namespace UID remapping or `setgroups deny` issue
- **Fails at Layer 3 but not Layer 2**: interaction between multiple features
- **Fails at Layer 4, test 16 but not 15**: confirms FUSE-specific (not namespace-generic)
- **Fails at Layer 5, test 18 but not 19**: confirms disorderfs-specific under full sandbox

## Architecture

- `run-tests.sh` — main test runner, all 20 tests self-contained
- `nix-sandbox-sim.sh` — Python-based sandbox simulator that reproduces the
  exact sequence from `linux-derivation-builder.cc`: `unshare(CLONE_NEWUSER|CLONE_NEWNS)`,
  `uid_map`/`gid_map` setup, `MS_PRIVATE`, bind-mounts, `pivot_root`, `chroot`,
  `setuid`/`setgid` drop

## Key Hypothesis

See `nix-sandbox.md` §8 for the full analysis. The leading hypothesis is:

> The `setgroups deny` written to `/proc/<pid>/setgroups` in the user namespace
> causes `fuse_getgroups()` to return an empty list. disorderfs's `drop_privileges()`
> then clears all supplementary groups via `thread_setgroups(0, NULL)` before
> accessing the backing filesystem, losing the `nixbld` group membership needed
> for group-based write permission on the backing directory.

Tests 08, 12, and the 15-vs-16 comparison are designed to confirm or refute this.
