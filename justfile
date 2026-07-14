# https://github.com/casey/just

set shell := ["bash", "-uc"]

odin_dir := env_var("HOME") / "odin-dev"
odin     := odin_dir / "odin"
odinfmt  := odin_dir / "odinfmt"
source   := "src"
binary   := `basename "$PWD"`
cache    := ".psycho_cache"

odin_release_api := "https://api.github.com/repos/odin-lang/Odin/releases/latest"
ols_release_api  := "https://api.github.com/repos/DanielGavin/ols/releases/latest"

[private]
default:
    @just --list


# Install the latest official Odin release.
setup:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ ! -x "{{odin}}" ]]; then
        case "$(uname -s)-$(uname -m)" in
            Linux-x86_64)  platform=linux-amd64 ;;
            Linux-aarch64) platform=linux-arm64 ;;
            Darwin-x86_64) platform=macos-amd64 ;;
            Darwin-arm64)  platform=macos-arm64 ;;
            *) echo "error: unsupported platform" >&2; exit 1 ;;
        esac

        tag="$(curl -fsSL "{{odin_release_api}}" | jq -r .tag_name)"
        url="https://github.com/odin-lang/Odin/releases/download/$tag/odin-$platform-$tag.tar.gz"

        mkdir -p "{{odin_dir}}"
        curl -fL "$url" |
            tar -xz --strip-components=1 -C "{{odin_dir}}"
    fi

    if [[ ! -x "{{odinfmt}}" ]]; then
        tag="$(curl -fsSL "{{ols_release_api}}" | jq -r .tag_name)"
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT

        curl -fL "https://github.com/DanielGavin/ols/archive/refs/tags/$tag.tar.gz" |
            tar -xz --strip-components=1 -C "$tmp"

        cd "$tmp"
        "{{odin}}" build tools/odinfmt/main.odin \
            -file \
            -collection:src=src \
            -out:"{{odinfmt}}" \
            -o:speed
    fi

    "{{odin}}" version


# Remove generated files.
clean:
    rm -rf "{{cache}}" "{{binary}}"


# Build.
build: setup
    {{odin}} build "{{source}}" -out:"{{binary}}" -o:speed

build-debug: setup
    {{odin}} build "{{source}}" -out:"{{binary}}" -debug -o:none

build-size: setup
    {{odin}} build "{{source}}" -out:"{{binary}}" -o:size

build-native: setup
    {{odin}} build "{{source}}" -out:"{{binary}}" -o:aggressive -microarch:native

build-timings: setup
    {{odin}} build "{{source}}" -out:"{{binary}}" -o:speed -show-more-timings


# Check.
check: setup
    {{odin}} check "{{source}}"

vet: setup
    {{odin}} check "{{source}}" -vet -vet-tabs -vet-style -vet-semicolon

lint: setup
    {{odin}} check "{{source}}" \
        -vet \
        -vet-tabs \
        -vet-style \
        -strict-style \
        -warnings-as-errors


# Format project Odin files.
fmt: setup
    find "{{source}}" -type f -name '*.odin' -exec "{{odinfmt}}" -w {} +


# Run.
run *args: setup
    {{odin}} run "{{source}}" -debug -- {{args}}

exec *args: build
    "./{{binary}}" {{args}}


# Test.
test: build-debug
    "./{{binary}}" --self-test

test-asan: setup
    {{odin}} build "{{source}}" \
        -out:"{{binary}}" \
        -debug \
        -sanitize:address \
        -vet
    "./{{binary}}" --self-test


# Everything.
all: fmt lint test build


# Odin environment.
info: setup
    {{odin}} version
    {{odin}} report
