#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
svm_dir=${SVM_DIR:-"${HOME}/.svm"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hermes-pinned-core.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

build_one() {
    local name=$1
    local version=$2
    local source_dir=$3
    mkdir -p "$tmp/$name/src"
    cp -a "$repo/lib/$source_dir/src/." "$tmp/$name/src/"
    cat > "$tmp/$name/foundry.toml" <<EOF
[profile.default]
solc_version = "$version"
optimizer = true
optimizer_runs = 200
via_ir = true
src = "src"
out = "out"
libs = []
EOF
    forge build --root "$tmp/$name" --contracts "src/$name.sol" \
        --use "$svm_dir/$version/solc-$version" --out "$repo/out-pinned/$name"
    mkdir -p "$repo/out"
    mkdir -p "$repo/out/$name.sol"
    cp "$repo/out-pinned/$name/$name.sol/$name.json" "$repo/out/$name.sol/$name.json"
}

build_one VaultV2 0.8.28 vault-v2
build_one Morpho 0.8.19 morpho-blue
build_one Midnight 0.8.34 midnight
printf 'Pinned core artifacts generated under out/{VaultV2,Morpho,Midnight}.sol/\n'
