# https://github.com/casey/just

set shell := ["bash", "-uc"]

odin   := "./odin-dev/odin"
binary := "psycho"
cache  := ".psycho_cache"

[private]
default:
    @just --list


# Remove generated files.
clean:
    rm -rf "{{cache}}" "{{binary}}"


# Normal optimized build.
build: clean
    {{odin}} build . -out:{{binary}} -o:speed


# Debug build with symbols and no optimization.
build-debug: clean
    {{odin}} build . -out:{{binary}} -debug -o:none


# Optimize for executable size.
build-size: clean
    {{odin}} build . -out:{{binary}} -o:size


# Aggressive native-machine build.
# Fast, but less portable and more aggressive than normal release builds.
build-native: clean
    {{odin}} build . \
        -out:{{binary}} \
        -o:aggressive \
        -microarch:native


# Build and print compiler timing information.
build-timings: clean
    {{odin}} build . \
        -out:{{binary}} \
        -o:speed \
        -show-more-timings


# Fast semantic/type check without producing an executable.
check:
    {{odin}} check .


# Additional compiler vetting.
vet:
    {{odin}} check . \
        -vet \
        -vet-tabs \
        -vet-style \
        -vet-semicolon


# Strict CI-style linting.
lint:
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
run *args:
    {{odin}} run . -debug -- {{args}}


# Run an already-built executable.
exec *args: build
    ./{{binary}} {{args}}


# Run Odin tests.
test:
    {{odin}} test . \
        -vet \
        -vet-tabs \
        -vet-style


# Run tests with AddressSanitizer.
test-asan:
    {{odin}} test . \
        -debug \
        -sanitize:address \
        -vet


# Format, lint, test, and build.
all: fmt lint test build


# Display compiler version and environment report.
info:
    {{odin}} version
    {{odin}} report
