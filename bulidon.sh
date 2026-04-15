#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_VOLUME_SIZE=8G
readonly STATE_DIR=/var/lib/buildon

function condStr() {
    if [[ $1 == "true" ]]; then echo "$2"; else echo "$3"; fi
}

function sx() {
    echo + sudo "$@" >&2
    sudo env "PATH=$PATH" "$@" || fail "operation failed"
}

function fail() {
    echo "Error: $*" >&2
    exit 1
}

function addRollbackStep() {
    echo "$@" | sudo tee -a "$STATE_DIR/rollback" >/dev/null ||
        fail "Failed to add rollback step"
}

function rollback() {
    local f cmd
    f="$STATE_DIR/rollback"
    if [[ ! -s $f ]]; then
        echo "No rollback steps to perform"
        return
    fi
    while [[ -s $f ]]; do
        cmd=$(tail -n 1 "$f")
        sudo sed -i '$ d' "$f"
        echo "+ $cmd" >&2
        if ! eval "$cmd" 2>/dev/null; then
            echo "Rollback step skipped (already clean): $cmd" >&2
        fi
    done
    echo "Rollback complete"
}

function disorder_helper() {
    local base="$1"
    local reverse="$2"
    local src
    src="$base/disorder$(condStr "$reverse" "-reverse" "")"
    local dst="${src}-mnt"

    sx install -d -m 0700 "$base" "$src" "$dst"
    addRollbackStep sudo rm -rf "$src" "$dst"

    sx disorderfs \
        --sort-dirents=yes \
        --multi-user=yes \
        --reverse-dirents="$(condStr "$reverse" "yes" "no")" \
        "$src" "$dst" >&2

    addRollbackStep sudo umount "$dst"

    echo "$dst"
}

function mkfs_helper() {
    local fs="$1"
    local src="$2"
    local size="${3:-$DEFAULT_VOLUME_SIZE}"
    local target="$src/$fs"
    local volume="$src/$fs.img"
    sx mkdir -p "$src" "$target"
    addRollbackStep sudo rm -rf "$src" "$target"
    sx truncate -s "$size" "$volume"
    addRollbackStep sudo rm -f "$volume"
    sx "mkfs.$fs" "$volume" >&2
    sx mount "$volume" "$target"
    addRollbackStep sudo umount "$target"
    echo "$target"
}

function reloadDaemon() {
    sx systemctl daemon-reload
    sx systemctl restart nix-daemon
}

function configure() {
    local path="$1"
    addRollbackStep sudo systemctl restart nix-daemon
    addRollbackStep sudo systemctl daemon-reload
    # Nix v2.22.0 added build-dir config option, see
    # https://nix.dev/manual/nix/2.22/command-ref/conf-file#conf-build-dir
    sudo cp /etc/nix/nix.conf /etc/nix/nix.conf.bak
    sudo sed -i '/^build-dir/d' /etc/nix/nix.conf
    echo "build-dir = $path" | sudo tee -a /etc/nix/nix.conf
    addRollbackStep sudo mv /etc/nix/nix.conf.bak /etc/nix/nix.conf
    reloadDaemon
}

function check() {
    local result
    # shellcheck disable=SC2016
    result="$(nix-build -E '(import <nixpkgs> {}).runCommand "buildon-check-'"$(date +%s)"'" {} "stat -f -c %T . > $out"' 2>/dev/null)" ||
        fail "Failed to run nix build"
    echo "nix build running on $(cat "$result")"
}

function main() {
    local path="$STATE_DIR/work"
    local size="$DEFAULT_VOLUME_SIZE"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --)
            shift
            break
            ;;
        --size=*)
            size="${1#*=}"
            shift
            ;;
        --check)
            check
            exit 0
            ;;
        --reset)
            rollback
            exit 0
            ;;
        --*)
            fail "Unknown option: $1"
            ;;
        *)
            break
            ;;
        esac
    done

    # Clean up previous state
    if ! rollback; then
        fail "Failed to rollback previous state"
    fi

    local tmpDir
    case "${1:?usage: bulidon <disorderfs|disorderfs-reverse|btrfs|ext4>}" in
    disorderfs)
        tmpDir=$(disorder_helper "$path" false)
        ;;
    disorderfs-reverse)
        tmpDir=$(disorder_helper "$path" true)
        ;;
    btrfs)
        tmpDir=$(mkfs_helper btrfs "$path" "$size")
        ;;
    ext4)
        tmpDir=$(mkfs_helper ext4 "$path" "$size")
        ;;
    *)
        fail "Unknown fs: $1"
        ;;
    esac

    if ! configure "$tmpDir"; then
        fail "Failed to configure nix"
    fi
}

main "$@"
