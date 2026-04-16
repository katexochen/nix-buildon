# nix-buildon

Configure the Nix daemon to run builds on a specific filesystem.
This is useful for testing [reproducible builds](https://reproducible-builds.org/).
For example, using `disorderfs` to surface build issues caused by non-deterministic directory entry ordering.
The filesystem is a one of the major impurities in the Nix sandbox.

To do this, nix-buildon creates the required filesystems setup and configured the Nix daemon via `build-dir` config setting to use it.

## Usage

```
nix-buildon [OPTIONS] <FILESYSTEM>
```

### Filesystem support

| Filesystem           | Description                                            |
| -------------------- | ------------------------------------------------------ |
| [`disorderfs`](#disorderfs)         | Randomize directory entry order using disorderfs (fuse)|
| [`disorderfs-reverse`](#disorderfs) | Reverse directory entry order using disorderfs (fuse)  |
| `btrfs`              | Create and mount a btrfs image for builds              |
| `ext4`               | Create and mount an ext4 image for builds              |

### Options

| Option        | Description                                                     |
| ------------- | --------------------------------------------------------------- |
| `--size=SIZE` | Size of the filesystem image (default: `30G`, btrfs/ext4 only)  |
| `--check`     | Print the filesystem type builds are currently running on       |
| `--reset`     | Roll back to the previous configuration                         |
| `-h, --help`  | Show help message                                               |

## disorderfs

[disorderfs](https://salsa.debian.org/reproducible-builds/disorderfs) is a fuse filesystem developed by the Reproducible Builds project.
It is used to introduce randomness or determinism to filesystem metadata like directory ordering.

> [!WARNING]
> To make the Nix sandbox work on top of disorderfs, this project patches out the kernel-level DAC permission check (`default_permissions`).
> The patched disorderfs relies on its own privilege-dropping mechanism and trusts that the FUSE kernel module has already authorized each request.
> Do not expose this patched disorderfs mount to untrusted users.

## Examples

Run Nix builds on a disorderfs mount to detect directory ordering issues:

```bash
sudo nix-buildon disorderfs
```

Check what filesystem builds are currently using (should show fuse for disoderfs):

```bash
sudo nix-buildon --check
```

Build something (for example the `order` package in this flake):

```bash
nix build .#order && cat result
```
```
a
b
c
env-vars
```

Switch to disorderfs with reversed ordering:

```bash
sudo nix-buildon disorderfs-reverse
```

Build again:

```bash
nix build --rebuild --keep-failed .#order
```
```
error: derivation '/nix/store/xdnzc7cqy1vzkvrilkbk1ysb6pnfk6q2-order-test.drv'
    may not be deterministic: output "/nix/store/zl80ifqcqkj0620ndcbsnkxglypim53j-order-test"
    differs from "/nix/store/zl80ifqcqkj0620ndcbsnkxglypim53j-order-test.check"
```
```bash
cat /nix/store/zl80ifqcqkj0620ndcbsnkxglypim53j-order-test.check
```
```
env-vars
c
b
a
```

Roll back to the original configuration:

```bash
sudo nix-buildon --reset
```

Notice that `--reset` will restore a config backup from the time the nix-buildon configured the `build-dir`.
Any changes made to the config in the meantime will be lost.
<!-- TODO: maybe it should only revert the build-dir instead? -->

## Installation

This project is packaged as a Nix flake. You can run it directly:

```bash
nix shell github:katexochen/nix-buildon
```

Or add it to your system packages via the flake.

---

This project was made (in huge parts) at [OceanSprint](https://oceansprint.org/)!
