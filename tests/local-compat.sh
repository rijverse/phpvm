#!/bin/bash
# Run compat tests locally via Docker across Ubuntu versions.
# Usage: bash tests/local-compat.sh [18.04|20.04|22.04|24.04|all]
# Requires: docker

set -euo pipefail

VERSIONS=('18.04' '20.04' '22.04' '24.04')
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

if ! command -v docker &>/dev/null; then
    echo "docker not found" >&2
    exit 1
fi

run_version() {
    local ver="$1"
    local image="ubuntu:${ver}"
    echo ""
    echo "========================================"
    echo "  Ubuntu ${ver}"
    echo "========================================"

    docker run --rm \
        -v "${ROOT}:/phpvm:ro" \
        -w /phpvm \
        -e DEBIAN_FRONTEND=noninteractive \
        "$image" \
        bash -c '
            apt-get update -qq
            apt-get install -y -qq bash dpkg php-cli python3 python3-gi \
                gir1.2-gtk-3.0 xvfb shellcheck 2>/dev/null || true
            apt-get install -y -qq gir1.2-ayatana-appindicator3-0.1 2>/dev/null \
                || apt-get install -y -qq gir1.2-appindicator3-0.1 2>/dev/null || true
            echo ""
            bash tests/test_cli.sh phpvm.sh
            echo ""
            bash tests/test_gui.sh phpvm-gui.py
        '
}

if [[ "$TARGET" == "all" ]]; then
    failed=()
    for v in "${VERSIONS[@]}"; do
        run_version "$v" && true || failed+=("$v")
    done
    echo ""
    echo "========================================"
    if [[ "${#failed[@]}" -eq 0 ]]; then
        echo "  All versions passed."
    else
        echo "  FAILED on: ${failed[*]}"
        exit 1
    fi
else
    run_version "$TARGET"
fi
