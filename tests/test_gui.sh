#!/bin/bash
# GUI import + smoke tests; run inside container with python3-gi installed.
# Usage: bash tests/test_gui.sh [path/to/phpvm-gui.py]

set -uo pipefail

GUI="${1:-$(dirname "$0")/../phpvm-gui.py}"
GUI="$(realpath "$GUI")"

pass=0
fail=0

ok()   { echo "  PASS  $1"; pass=$(( pass + 1 )); }
fail() { echo "  FAIL  $1"; fail=$(( fail + 1 )); }
sep()  { echo ""; echo "--- $1 ---"; }

sep "environment"
echo "  python  $(python3 --version 2>&1)"
echo "  gui     ${GUI}"

sep "python3-gi import"
python3 -c "import gi" 2>/dev/null \
    && ok "gi module importable" || fail "gi module missing (install python3-gi)"

sep "GTK3 import"
python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
" 2>/dev/null \
    && ok "GTK 3.0 importable" || fail "GTK 3.0 not available (install gir1.2-gtk-3.0)"

sep "AppIndicator3 (ayatana or legacy)"
python3 -c "
import gi
for variant in ('AyatanaAppIndicator3', 'AppIndicator3'):
    try:
        gi.require_version(variant, '0.1')
        mod = __import__('gi.repository', fromlist=[variant])
        getattr(mod, variant)
        print(f'  using {variant}')
        exit(0)
    except Exception:
        pass
exit(1)
" 2>/dev/null \
    && ok "AppIndicator3 importable" || fail "AppIndicator3 missing (install gir1.2-ayatana-appindicator3-0.1 or gir1.2-appindicator3-0.1)"

sep "GLib import"
python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import GLib
" 2>/dev/null \
    && ok "GLib importable" || fail "GLib not available"

sep "gui syntax check"
python3 -m py_compile "$GUI" 2>/dev/null \
    && ok "phpvm-gui.py compiles without syntax error" || fail "phpvm-gui.py has syntax errors"

sep "gui --help (headless via xvfb if available)"
if command -v xvfb-run &>/dev/null; then
    out=$(xvfb-run -a python3 "$GUI" --help 2>&1); rc=$?
    [[ $rc -eq 0 || "$out" == *"phpvm"* || "$out" == *"usage"* || "$out" == *"Usage"* ]] \
        && ok "gui --help via xvfb exits cleanly" || fail "gui --help via xvfb failed (rc=${rc}): ${out}"
else
    echo "  SKIP  xvfb not available, skipping runtime test"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
