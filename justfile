# https://github.com/casey/just

set shell := ["bash", "-uc"]

odin_dir         := "./odin-dev"
odin             := "./odin-dev/odin"
odin_release_api := "https://api.github.com/repos/odin-lang/Odin/releases/latest"
binary           := "psycho"
cache            := ".psycho_cache"

[private]
default:
    @just --list


# Download the latest official Odin release; existing installs are reused.
setup:
    #!/usr/bin/env bash
    set -euo pipefail

    target="{{odin_dir}}"
    compiler="{{odin}}"

    if [[ -x "$compiler" ]]; then
        echo "Odin already installed: $("$compiler" version)"
        exit 0
    fi

    if [[ -e "$target" ]]; then
        echo "error: $target exists, but $compiler is not executable" >&2
        echo "Move or remove that directory, then run 'just setup' again." >&2
        exit 1
    fi

    for tool in curl tar awk; do
        if ! command -v "$tool" >/dev/null; then
            echo "error: '$tool' is required to install Odin" >&2
            exit 1
        fi
    done

    case "$(uname -s)" in
        Linux)  platform="linux" ;;
        Darwin) platform="macos" ;;
        *)
            echo "error: automatic Odin setup supports Linux and macOS" >&2
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) architecture="amd64" ;;
        arm64|aarch64) architecture="arm64" ;;
        *)
            echo "error: automatic Odin setup supports AMD64 and ARM64" >&2
            exit 1
            ;;
    esac

    temporary="$(mktemp -d "${TMPDIR:-/tmp}/psycho-odin.XXXXXX")"
    trap 'rm -rf "$temporary"' EXIT
    release_json="$temporary/release.json"
    archive="$temporary/odin.tar.gz"
    unpacked="$temporary/unpacked"

    echo "Finding the latest Odin release for ${platform}-${architecture}..."
    curl -fsSL --retry 3 "{{odin_release_api}}" -o "$release_json"

    asset_url="$(
        awk -v stem="odin-${platform}-${architecture}-dev-" '
            /"browser_download_url":/ && index($0, stem) {
                value = $0
                sub(/^.*"browser_download_url": "/, "", value)
                sub(/".*$/, "", value)
                if (value ~ /\.tar\.gz$/) {
                    print value
                    exit
                }
            }
        ' "$release_json"
    )"

    if [[ -z "$asset_url" ]]; then
        echo "error: the latest release has no ${platform}-${architecture} archive" >&2
        exit 1
    fi

    echo "Downloading ${asset_url##*/}..."
    curl -fL --retry 3 --progress-bar "$asset_url" -o "$archive"
    mkdir "$unpacked"
    tar -xzf "$archive" -C "$unpacked"

    extracted_compiler=""
    for candidate in "$unpacked/odin" "$unpacked"/*/odin; do
        if [[ -f "$candidate" ]]; then
            extracted_compiler="$candidate"
            break
        fi
    done
    if [[ -z "$extracted_compiler" || ! -x "$extracted_compiler" ]]; then
        echo "error: the downloaded archive does not contain an executable Odin compiler" >&2
        exit 1
    fi

    install_root="${extracted_compiler%/odin}"
    for directory in base core vendor; do
        if [[ ! -d "$install_root/$directory" ]]; then
            echo "error: the downloaded archive is missing '$directory/'" >&2
            exit 1
        fi
    done

    "$extracted_compiler" version >/dev/null
    mv "$install_root" "$target"
    echo "Installed $("$compiler" version) in $target"


# Remove generated files.
clean:
    rm -rf "{{cache}}" "{{binary}}"


# Normal optimized build.
build: setup clean
    {{odin}} build . -out:{{binary}} -o:speed


# Debug build with symbols and no optimization.
build-debug: setup clean
    {{odin}} build . -out:{{binary}} -debug -o:none


# Optimize for executable size.
build-size: setup clean
    {{odin}} build . -out:{{binary}} -o:size


# Aggressive native-machine build.
# Fast, but less portable and more aggressive than normal release builds.
build-native: setup clean
    {{odin}} build . \
        -out:{{binary}} \
        -o:aggressive \
        -microarch:native


# Build and print compiler timing information.
build-timings: setup clean
    {{odin}} build . \
        -out:{{binary}} \
        -o:speed \
        -show-more-timings


# Fast semantic/type check without producing an executable.
check: setup
    {{odin}} check .


# Additional compiler vetting.
vet: setup
    {{odin}} check . \
        -vet \
        -vet-tabs \
        -vet-style \
        -vet-semicolon


# Strict CI-style linting.
lint: setup
    {{odin}} check . \
        -vet \
        -vet-tabs \
        -vet-style \
        -strict-style \
        -warnings-as-errors


# Format project Odin files.
# Requires `odinfmt` from OLS to be available in PATH.
# Excludes the vendored Odin compiler and generated cache.
fmt:
    @command -v odinfmt >/dev/null || { \
        echo "error: odinfmt is not installed or not in PATH"; \
        exit 1; \
    }
    find . \
        -type f \
        -name '*.odin' \
        ! -path './odin-dev/*' \
        ! -path './.psycho_cache/*' \
        -exec odinfmt -w {} \;


# Run the project in debug mode.
# Example: just run --level test.json
run *args: setup
    {{odin}} run . -debug -- {{args}}


# Run an already-built executable.
exec *args: build
    ./{{binary}} {{args}}


# Run Odin tests.
test: setup
    {{odin}} test . \
        -vet \
        -vet-tabs \
        -vet-style


# Run tests with AddressSanitizer.
test-asan: setup
    {{odin}} test . \
        -debug \
        -sanitize:address \
        -vet


# Format, lint, test, and build.
all: fmt lint test build


# Display compiler version and environment report.
info: setup
    {{odin}} version
    {{odin}} report
