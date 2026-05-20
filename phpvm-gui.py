#!/usr/bin/env python3
"""phpvm system tray GUI — requires python3-gi, GTK3, and an AppIndicator
backend. Ayatana AppIndicator3 is preferred; legacy AppIndicator3 also works.

    sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1
"""

import os
import sys

# double fork before importing gi/Gtk. forking after GTK/D-Bus init leaves
# the child with a stale main-context and can hang or crash. detach unless
# --foreground (debugging) or --help (we want help text on stdout).
_FG_FLAGS = {"--foreground", "-F", "--help", "-h"}
if not _FG_FLAGS.intersection(sys.argv[1:]):
    try:
        if os.fork() > 0:
            os._exit(0)
        os.setsid()
        if os.fork() > 0:
            os._exit(0)
        os.chdir("/")
        os.umask(0o022)
        _devnull = os.open(os.devnull, os.O_RDWR)
        for _fd in (0, 1, 2):
            try:
                os.dup2(_devnull, _fd)
            except OSError:
                pass
        if _devnull > 2:
            os.close(_devnull)
    except OSError:
        # fork not available (e.g. some sandboxes). run in foreground.
        pass

import fcntl
import json
import re
import shutil
import signal
import subprocess
import threading
from datetime import date
from pathlib import Path

try:
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, Gdk, GLib, Gio
except ImportError:
    print("Error: python3-gi required.")
    print("Install: sudo apt install python3-gi gir1.2-gtk-3.0")
    sys.exit(1)

AppIndicator3 = None
IndicatorCategory = None
IndicatorStatus = None

for variant in ('AyatanaAppIndicator3', 'AppIndicator3'):
    try:
        gi.require_version(variant, '0.1')
        mod = __import__('gi.repository', fromlist=[variant])
        AppIndicator3 = getattr(mod, variant)
        IndicatorCategory = AppIndicator3.IndicatorCategory
        IndicatorStatus = AppIndicator3.IndicatorStatus
        break
    except (ValueError, ImportError, AttributeError):
        continue

REFRESH_MS = 15000

_CSS = b"""
@define-color elephant_body #8892BF;
@define-color elephant_dark #727FAF;
@define-color elephant_eye  #3a4882;
@define-color badge_green   #2da44e;
@define-color badge_red     #cf222e;

headerbar { min-height: 46px; }
headerbar .subtitle {
    color: @elephant_eye;
    font-family: "Inter", "Adwaita Sans", "Cantarell", sans-serif;
}

.phpvm-mono {
    font-family: "JetBrains Mono", "Fira Code", "DejaVu Sans Mono", monospace;
}

listbox { border-radius: 6px; background: transparent; }
listboxrow { background-color: @theme_base_color; }
listboxrow:first-child { border-radius: 6px 6px 0 0; }
listboxrow:last-child  { border-radius: 0 0 6px 6px; }
listboxrow + listboxrow { border-top: 1px solid alpha(@borders, 0.5); }
listboxrow:hover { background-color: alpha(@elephant_body, 0.10); }

.phpvm-card {
    border: 1px solid alpha(@elephant_dark, 0.35);
    border-radius: 6px;
}

.badge {
    border-radius: 2em;
    padding: 1px 8px;
    font-size: smaller;
    font-weight: bold;
    color: white;
    min-height: 0;
}
.badge-blue  { background-color: #0969da; }
.badge-amber { background-color: #bf8700; }
.badge-green { background-color: @badge_green; }
.badge-red   { background-color: @badge_red; }
.badge-gray  { background-color: #6e7781; }

.status-bar {
    padding: 4px 8px;
    border-radius: 4px;
    background-color: alpha(@elephant_body, 0.12);
}

button.btn-switch {
    background-image: none;
    background-color: @badge_green;
    color: white;
    border: 1px solid shade(@badge_green, 0.85);
    text-shadow: none;
}
button.btn-switch:hover  { background-color: shade(@badge_green, 1.06); }
button.btn-switch:active { background-color: shade(@badge_green, 0.92); }

button.btn-active:disabled,
button.btn-active {
    background-image: none;
    background-color: alpha(@badge_green, 0.18);
    color: @badge_green;
    border: 1px solid alpha(@badge_green, 0.30);
    text-shadow: none;
    opacity: 1;
}
"""

_VERSION_RE = re.compile(r"(\d+\.\d+)")

_ICON_CANDIDATES = [
    "/usr/share/icons/hicolor/scalable/apps/phpvm.svg",
    str(Path.home() / ".local/share/icons/hicolor/scalable/apps/phpvm.svg"),
    "/usr/local/share/icons/hicolor/scalable/apps/phpvm.svg",
]
APP_ICON = next((p for p in _ICON_CANDIDATES if Path(p).exists()), "dialog-information")

# per process caches, these probe disk/subprocess for every PHP version on
# every refresh, which is wasteful. Invalidate via clear_caches() after switch.
_sapis_cache: dict = {}
_xdebug_cache: dict = {}
_ini_cache: dict = {}


def clear_caches():
    _sapis_cache.clear()
    _xdebug_cache.clear()
    _ini_cache.clear()


def run(args):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=10)
        return r.stdout.strip(), r.returncode
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "", 1


def get_versions():
    out, code = run(["update-alternatives", "--list", "php"])
    if code != 0:
        return []
    return sorted(out.splitlines())


def get_current():
    p = Path("/etc/alternatives/php")
    try:
        return str(p.resolve()) if p.is_symlink() else ""
    except OSError:
        return ""


def switch_php(target):
    # fast path: passwordless sudo (sudoers NOPASSWD configured by install.sh)
    try:
        r = subprocess.run(
            ["sudo", "-n", "update-alternatives", "--set", "php", target],
            capture_output=True, text=True, timeout=15,
        )
        if r.returncode == 0:
            return True, None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # fallback: polkit graphical auth dialog (no terminal needed)
    try:
        r = subprocess.run(
            ["pkexec", "update-alternatives", "--set", "php", target],
            capture_output=True, text=True, timeout=30,
        )
        return r.returncode == 0, (r.stderr.strip() or None)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        return False, "no_pkexec"


def normalize_version(raw):
    if not raw:
        return None
    s = "".join(raw.split())
    if s.startswith("php"):
        s = s[3:]
    m = _VERSION_RE.match(s)
    return m.group(1) if m else None


def detect_project_php(directory=None):
    """resolve project PHP version. prefer the CLI's solver (handles composer
    constraints like ^7.4 || ^8.0) so behavior matches the shell side exactly.
    falls back to a local walk if phpvm isn't on PATH.
    """
    cwd = directory or os.getcwd()

    if shutil.which("phpvm"):
        try:
            r = subprocess.run(
                ["phpvm", "--auto", "--print", cwd],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0:
                norm = normalize_version(r.stdout)
                if norm:
                    return norm
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    start = Path(cwd).resolve()

    d = start
    while True:
        f = d / ".php-version"
        if f.exists():
            return normalize_version(f.read_text())
        if d == d.parent:
            break
        d = d.parent

    d = start
    while True:
        composer = d / "composer.json"
        if composer.exists():
            try:
                data = json.loads(composer.read_text())
                req = data.get("require", {}).get("php", "")
                m = _VERSION_RE.search(req)
                if m:
                    return m.group(1)
            except Exception:
                pass
            return None
        if d == d.parent:
            break
        d = d.parent
    return None


def version_label(path):
    name = Path(path).name
    m = re.search(r"(\d+\.\d+)", name)
    return f"PHP {m.group(1)}" if m else name


def notify(title, body, urgent=False):
    try:
        subprocess.Popen(
            ["notify-send", title, body,
             f"--urgency={'critical' if urgent else 'normal'}",
             f"--icon={APP_ICON}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except FileNotFoundError:
        pass


# ---------- inspection helpers (for the window mode) ----------

# PHP EOL dates from php.net/supported-versions.php (security-support end).
PHP_EOL = {
    "5.6": date(2018, 12, 31),
    "7.0": date(2019, 1, 10),
    "7.1": date(2019, 12, 1),
    "7.2": date(2020, 11, 30),
    "7.3": date(2021, 12, 6),
    "7.4": date(2022, 11, 28),
    "8.0": date(2023, 11, 26),
    "8.1": date(2025, 12, 31),
    "8.2": date(2026, 12, 31),
    "8.3": date(2027, 12, 31),
    "8.4": date(2028, 12, 31),
}


def version_num(path_or_name):
    name = Path(path_or_name).name if "/" in str(path_or_name) else str(path_or_name)
    m = re.search(r"(\d+\.\d+)", name)
    return m.group(1) if m else ""


def is_eol(version):
    eol = PHP_EOL.get(version)
    if not eol:
        return None
    return date.today() > eol


def get_sapis(version):
    if version in _sapis_cache:
        return _sapis_cache[version]
    sapis = []
    if shutil.which(f"php{version}"):
        sapis.append("cli")
    if Path(f"/usr/sbin/php-fpm{version}").exists():
        sapis.append("fpm")
    if Path(f"/etc/apache2/mods-available/php{version}.conf").exists():
        sapis.append("apache2")
    _sapis_cache[version] = sapis
    return sapis


def get_fpm_status(version):
    if not shutil.which("systemctl"):
        return None
    out, code = run(["systemctl", "is-active", f"php{version}-fpm"])
    if code == 0:
        return "active"
    if out in ("inactive", "failed", "activating", "deactivating"):
        return out
    return None


def get_xdebug_status(version):
    if version in _xdebug_cache:
        return _xdebug_cache[version]
    out, code = run([f"php{version}", "-m"])
    if code != 0:
        _xdebug_cache[version] = None
        return None
    res = any(line.strip().lower() == "xdebug" for line in out.splitlines())
    _xdebug_cache[version] = res
    return res


def get_ini_path(version):
    if version in _ini_cache:
        return _ini_cache[version]
    out, code = run([f"php{version}", "--ini"])
    if code != 0:
        _ini_cache[version] = None
        return None
    for line in out.splitlines():
        if "Loaded Configuration File" in line and ":" in line:
            res = line.split(":", 1)[1].strip()
            _ini_cache[version] = res
            return res
    _ini_cache[version] = None
    return None


def reload_fpm(version):
    # fast path: passwordless sudo
    try:
        r = subprocess.run(
            ["sudo", "-n", "systemctl", "restart", f"php{version}-fpm"],
            capture_output=True, text=True, timeout=15,
        )
        if r.returncode == 0:
            return True, None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # fallback: polkit graphical auth dialog
    try:
        r = subprocess.run(
            ["pkexec", "systemctl", "restart", f"php{version}-fpm"],
            capture_output=True, text=True, timeout=30,
        )
        return r.returncode == 0, (r.stderr.strip() or None)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        return False, "no_pkexec"


# ---------- window mode ----------

class PHPSwitcherWindow(Gtk.Window):
    def __init__(self, on_switch=None):
        super().__init__()
        self.set_default_size(720, 520)
        if APP_ICON.startswith("/"):
            try:
                self.set_icon_from_file(APP_ICON)
            except Exception:
                self.set_icon_name("dialog-information")
        else:
            self.set_icon_name(APP_ICON)

        # apply CSS
        css_provider = Gtk.CssProvider()
        css_provider.load_from_data(_CSS)
        screen = Gdk.Screen.get_default()
        if screen:
            Gtk.StyleContext.add_provider_for_screen(
                screen, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        self._on_switch_cb = on_switch

        # header bar
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.set_title("phpvm")
        hb.set_subtitle("PHP Version Manager")
        self.set_titlebar(hb)

        refresh_btn = Gtk.Button()
        refresh_btn.set_image(Gtk.Image.new_from_icon_name("view-refresh-symbolic", Gtk.IconSize.BUTTON))
        refresh_btn.set_tooltip_text("Refresh")
        refresh_btn.connect("clicked", self._on_refresh)
        hb.pack_end(refresh_btn)

        folder_btn = Gtk.Button()
        folder_btn.set_image(Gtk.Image.new_from_icon_name("folder-open-symbolic", Gtk.IconSize.BUTTON))
        folder_btn.set_tooltip_text("Pick project folder…")
        folder_btn.connect("clicked", self._on_folder)
        hb.pack_end(folder_btn)

        auto_btn = Gtk.Button(label="Auto-detect")
        auto_btn.connect("clicked", self._on_auto)
        hb.pack_start(auto_btn)

        # body
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_margin_top(14)
        outer.set_margin_bottom(10)
        outer.set_margin_start(14)
        outer.set_margin_end(14)
        self.add(outer)

        self.header_label = Gtk.Label(xalign=0)
        self.header_label.set_use_markup(True)
        outer.pack_start(self.header_label, False, False, 0)

        self.project_label = Gtk.Label(xalign=0)
        self.project_label.set_line_wrap(True)
        outer.pack_start(self.project_label, False, False, 0)

        # card-framed list
        card = Gtk.Frame()
        card.get_style_context().add_class("phpvm-card")
        card.set_shadow_type(Gtk.ShadowType.NONE)
        outer.pack_start(card, True, True, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        card.add(scroll)

        self.list_box = Gtk.ListBox()
        self.list_box.set_selection_mode(Gtk.SelectionMode.NONE)
        scroll.add(self.list_box)

        self.status_label = Gtk.Label(xalign=0)
        self.status_label.set_use_markup(True)
        self.status_label.set_markup("<small> </small>")
        self.status_label.get_style_context().add_class("status-bar")
        outer.pack_start(self.status_label, False, False, 0)

        self.refresh()

    def refresh(self):
        for child in self.list_box.get_children():
            self.list_box.remove(child)

        current = get_current()
        php_v_out, _ = run(["php", "--version"])
        php_v_line = php_v_out.splitlines()[0] if php_v_out else ""

        if current:
            self.header_label.set_markup(
                f'<b>Active:</b> '
                f'<span foreground="#2da44e"><b>{GLib.markup_escape_text(Path(current).name)}</b></span>'
                f'  <span foreground="#57606a"><small>{GLib.markup_escape_text(php_v_line)}</small></span>'
            )
        else:
            self.header_label.set_markup("<b>Active:</b> <i>unknown</i>")

        proj = detect_project_php()
        if proj:
            self.project_label.set_markup(
                f'<span foreground="#57606a"><small>'
                f'<b>Project requires PHP {GLib.markup_escape_text(proj)}</b>'
                f'  — {GLib.markup_escape_text(os.getcwd())}'
                f'</small></span>'
            )
        else:
            self.project_label.set_markup(
                '<span foreground="#57606a"><small><i>No .php-version or composer.json in current directory</i></small></span>'
            )

        for v in get_versions():
            self.list_box.add(self._build_row(v, current))

        self.list_box.show_all()

    def _build_row(self, v, current):
        ver = version_num(v)
        active = (v == current)

        row = Gtk.ListBoxRow()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(12)
        box.set_margin_end(12)
        row.add(box)

        name_label = Gtk.Label(xalign=0)
        name_label.set_use_markup(True)
        name_label.get_style_context().add_class("phpvm-mono")
        if active:
            name_label.set_markup(
                f'<span foreground="#2da44e"><b>{GLib.markup_escape_text(Path(v).name)}</b></span>'
            )
        else:
            name_label.set_markup(GLib.markup_escape_text(Path(v).name))
        name_label.set_size_request(120, -1)
        box.pack_start(name_label, False, False, 0)

        badges = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        badges.set_valign(Gtk.Align.CENTER)
        for sapi in get_sapis(ver):
            badges.pack_start(self._badge(sapi, "badge-blue"), False, False, 0)

        if get_xdebug_status(ver):
            badges.pack_start(self._badge("xdebug", "badge-amber"), False, False, 0)

        fpm = get_fpm_status(ver)
        if fpm == "active":
            badges.pack_start(self._badge("fpm ●", "badge-green"), False, False, 0)
        elif fpm in ("inactive", "failed"):
            badges.pack_start(self._badge(f"fpm: {fpm}", "badge-gray"), False, False, 0)

        eol = is_eol(ver)
        if eol is True:
            badges.pack_start(self._badge("EOL", "badge-red"), False, False, 0)

        box.pack_start(badges, True, True, 0)

        switch_btn = Gtk.Button(label="Active" if active else "Switch")
        switch_btn.set_sensitive(not active)
        switch_btn.get_style_context().add_class("btn-active" if active else "btn-switch")
        switch_btn.connect("clicked", self._on_switch, v)
        box.pack_end(switch_btn, False, False, 0)

        if "fpm" in get_sapis(ver):
            reload_btn = Gtk.Button(label="Restart FPM")
            reload_btn.set_tooltip_text(f"sudo systemctl restart php{ver}-fpm")
            reload_btn.connect("clicked", self._on_reload_fpm, ver)
            box.pack_end(reload_btn, False, False, 0)

        ini = get_ini_path(ver)
        if ini:
            row.set_tooltip_text(f"php.ini: {ini}")

        return row

    def _badge(self, text, css_class):
        lbl = Gtk.Label(label=text)
        ctx = lbl.get_style_context()
        ctx.add_class("badge")
        ctx.add_class(css_class)
        return lbl

    def _on_switch(self, _btn, target):
        name = Path(target).name
        self._set_status(f"Switching to {name}…")
        def worker():
            ok, err = switch_php(target)
            GLib.idle_add(self._post_switch, ok, name, err)
        threading.Thread(target=worker, daemon=True).start()

    def _post_switch(self, ok, name, err):
        if ok:
            clear_caches()
            self._set_status(f"✓ Switched to {name}", ok=True)
            if self._on_switch_cb:
                self._on_switch_cb()
        else:
            self._set_status(f"✗ Failed to switch to {name}" + (f": {err}" if err else ""), ok=False)
        self.refresh()
        return False

    def _on_reload_fpm(self, _btn, ver):
        def worker():
            ok, err = reload_fpm(ver)
            GLib.idle_add(self._post_fpm, ok, ver, err)
        threading.Thread(target=worker, daemon=True).start()

    def _post_fpm(self, ok, ver, err):
        if ok:
            self._set_status(f"✓ Restarted php{ver}-fpm", ok=True)
        else:
            self._set_status(f"✗ Failed to restart php{ver}-fpm" + (f": {err}" if err else ""), ok=False)
        self.refresh()
        return False

    def _set_status(self, msg, ok=None):
        if ok is True:
            markup = f'<b><span foreground="#2da44e">{GLib.markup_escape_text(msg)}</span></b>'
        elif ok is False:
            markup = f'<b><span foreground="#cf222e">{GLib.markup_escape_text(msg)}</span></b>'
        else:
            markup = f'<i><span foreground="#6e7781">{GLib.markup_escape_text(msg)}</span></i>'
        self.status_label.set_markup(markup)

    def _on_refresh(self, _btn):
        clear_caches()
        self.refresh()
        self._set_status("Refreshed")

    def _on_auto(self, _btn):
        proj = detect_project_php()
        if not proj:
            self._set_status("No .php-version or composer.json found", ok=False)
            return
        target = next(
            (v for v in get_versions() if Path(v).name == f"php{proj}"), None
        )
        if not target:
            self._set_status(f"PHP {proj} required but not installed", ok=False)
            return
        self._set_status(f"Project: {os.getcwd()} → PHP {proj}")
        if target == get_current():
            return
        self._on_switch(None, target)

    def _on_folder(self, _btn):
        dialog = Gtk.FileChooserDialog(
            title="Select project folder",
            parent=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK,
        )
        dialog.set_modal(False)
        dialog.connect("response", self._on_folder_response)
        dialog.show()

    def _on_folder_response(self, dialog, response):
        folder = dialog.get_filename() if response == Gtk.ResponseType.OK else None
        dialog.destroy()
        if not folder:
            return
        proj = detect_project_php(folder)
        if not proj:
            self._set_status("No .php-version or composer.json in that folder", ok=False)
            return
        target = next(
            (v for v in get_versions() if Path(v).name == f"php{proj}"), None
        )
        if not target:
            self._set_status(f"PHP {proj} required but not installed", ok=False)
            return
        self._set_status(f"Project: {folder} → PHP {proj}")
        if target == get_current():
            return
        self._on_switch(None, target)


class PHPSwitcherTray:
    def __init__(self):
        self.menu = Gtk.Menu()
        self.menu.connect("show", lambda _: self._build_menu())
        self._build_menu()

        label = self._tray_label()

        if AppIndicator3:
            self.indicator = AppIndicator3.Indicator.new(
                "phpvm",
                APP_ICON,
                IndicatorCategory.APPLICATION_STATUS
            )
            self.indicator.set_status(IndicatorStatus.ACTIVE)
            self.indicator.set_label(label, "PHP 99.99")
            self.indicator.set_menu(self.menu)
        else:
            print("Warning: AppIndicator3 not found, falling back to StatusIcon.")
            print("Install: sudo apt install gir1.2-ayatana-appindicator3-0.1")
            self.status_icon = Gtk.StatusIcon()
            self.status_icon.set_from_icon_name(APP_ICON if not APP_ICON.startswith("/") else "dialog-information")
            self.status_icon.set_tooltip_text(label)
            self.status_icon.connect("popup-menu", self._status_icon_popup)

        GLib.timeout_add(REFRESH_MS, self._tick)

        alt = Gio.File.new_for_path("/etc/alternatives/php")
        self._alt_monitor = alt.monitor_file(Gio.FileMonitorFlags.NONE, None)
        self._alt_monitor.connect("changed", self._on_alt_changed)

    def _on_alt_changed(self, _monitor, _f, _other, _event):
        clear_caches()
        GLib.idle_add(self._tray_refresh)
        if getattr(self, "_window", None) and self._window.get_visible():
            GLib.idle_add(self._window.refresh)

    def _tray_label(self):
        current = get_current()
        if current == getattr(self, "_last_current", None):
            return getattr(self, "_last_label", version_label(current) if current else "PHP ?")
        self._last_current = current
        self._last_label = version_label(current) if current else "PHP ?"
        return self._last_label

    def _build_menu(self):
        for item in self.menu.get_children():
            self.menu.remove(item)

        current = get_current()
        versions = get_versions()

        # Header
        header = Gtk.MenuItem(label=f"Active: {Path(current).name if current else 'unknown'}")
        header.set_sensitive(False)
        self.menu.append(header)

        proj = detect_project_php()
        if proj:
            proj_item = Gtk.MenuItem(label=f"Project requires: PHP {proj}")
            proj_item.set_sensitive(False)
            self.menu.append(proj_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        if versions:
            for v in versions:
                lbl = version_label(v) + ("  ✓" if v == current else "")
                item = Gtk.MenuItem(label=lbl)
                item.connect("activate", self._on_select, v)
                self.menu.append(item)
        else:
            item = Gtk.MenuItem(label="No PHP versions found")
            item.set_sensitive(False)
            self.menu.append(item)

        self.menu.append(Gtk.SeparatorMenuItem())

        auto_item = Gtk.MenuItem(label="Auto-detect from project")
        auto_item.connect("activate", self._on_auto)
        self.menu.append(auto_item)

        folder_item = Gtk.MenuItem(label="Auto-detect from folder…")
        folder_item.connect("activate", self._on_auto_folder)
        self.menu.append(folder_item)

        window_item = Gtk.MenuItem(label="Open phpvm window…")
        window_item.connect("activate", self._on_open_window)
        self.menu.append(window_item)

        tui_item = Gtk.MenuItem(label="Open Terminal UI")
        tui_item.connect("activate", self._on_tui)
        self.menu.append(tui_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _: Gtk.main_quit())
        self.menu.append(quit_item)

        self.menu.show_all()

    def _on_select(self, _widget, target):
        def worker():
            ok, err = switch_php(target)
            name = Path(target).name
            GLib.idle_add(self._post_switch, ok, name, err)
        threading.Thread(target=worker, daemon=True).start()

    def _post_switch(self, ok, name, err=None):
        if ok:
            clear_caches()
        self._refresh_label()
        self._build_menu()
        if ok:
            print(f"phpvm: switched to {name}")
            if getattr(self, "_window", None) and self._window.get_visible():
                self._window.refresh()
        else:
            print(f"phpvm: failed to switch to {name}" + (f" ({err})" if err else ""))
        return False

    def _on_auto(self, _widget, directory=None):
        proj = detect_project_php(directory)
        if not proj:
            notify("phpvm", "No .php-version or composer.json found")
            return

        versions = get_versions()
        target = next((v for v in versions if Path(v).name == f"php{proj}"), None)

        if not target:
            notify("phpvm", f"PHP {proj} required but not installed", urgent=True)
            return

        if target == get_current():
            notify("phpvm", f"Already on PHP {proj}")
            return

        def worker():
            ok, err = switch_php(target)
            GLib.idle_add(self._post_switch, ok, Path(target).name, err)
        threading.Thread(target=worker, daemon=True).start()

    def _on_auto_folder(self, _widget):
        dialog = Gtk.FileChooserDialog(
            title="Select project folder",
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK,
        )
        dialog.set_modal(False)
        dialog.connect("response", self._on_folder_response)
        dialog.show()

    def _on_folder_response(self, dialog, response):
        folder = dialog.get_filename() if response == Gtk.ResponseType.OK else None
        dialog.destroy()
        if folder:
            self._on_auto(None, directory=folder)

    def _on_open_window(self, _widget):
        self._window = PHPSwitcherWindow(on_switch=self._tray_refresh)
        self._window.show_all()

    def _tray_refresh(self):
        clear_caches()
        self._refresh_label()
        self._build_menu()

    def _on_tui(self, _widget):
        terminals = [
            ["gnome-terminal", "--", "phpvm"],
            ["xterm", "-e", "phpvm"],
            ["konsole", "-e", "phpvm"],
            ["xfce4-terminal", "-e", "phpvm"],
            ["x-terminal-emulator", "-e", "phpvm"],
        ]
        for cmd in terminals:
            if shutil.which(cmd[0]):
                subprocess.Popen(cmd)
                return
        notify("phpvm", "No terminal emulator found", urgent=True)

    def _status_icon_popup(self, icon, button, time):
        self._build_menu()
        self.menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, button, time)

    def _refresh_label(self):
        label = self._tray_label()
        if AppIndicator3:
            self.indicator.set_label(label, "PHP 99.99")
        else:
            self.status_icon.set_tooltip_text(label)

    def _tick(self):
        clear_caches()
        self._refresh_label()
        self._build_menu()
        return True


def _acquire_instance_lock():
    lock_dir = Path(os.environ.get("XDG_RUNTIME_DIR", Path.home() / ".cache" / "phpvm"))
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_path = lock_dir / "phpvm-gui.lock"
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fd.write(str(os.getpid()))
        fd.flush()
        return fd
    except OSError:
        fd.close()
        return None


def main():
    # daemonization already happened at module load (top of file).
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    args = sys.argv[1:]
    mode = "tray"
    if "--window" in args or "-w" in args:
        mode = "window"
    elif "--help" in args or "-h" in args:
        print("Usage: phpvm-gui [--window|-w] [--foreground|-F] [--help]")
        print("  (no args)      Run as system tray applet")
        print("  --window       Open the picker window directly (no tray)")
        print("  --foreground   Don't detach from terminal (debugging)")
        return

    if mode == "tray":
        _lock = _acquire_instance_lock()
        if _lock is None:
            sys.exit(0)
        PHPSwitcherTray()
    else:
        win = PHPSwitcherWindow()
        win.connect("destroy", Gtk.main_quit)
        win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
