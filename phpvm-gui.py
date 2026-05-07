#!/usr/bin/env python3
"""phpvm system tray GUI — requires python3-gi, GTK3, and AppIndicator3.

    sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
from datetime import date
from pathlib import Path

try:
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, GLib
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

REFRESH_MS = 5000


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


def can_sudo_nopasswd(cmd="update-alternatives"):
    try:
        r = subprocess.run(
            ["sudo", "-n", cmd, "--help"],
            capture_output=True, text=True, timeout=5,
        )
        return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def can_sudo_systemctl():
    try:
        r = subprocess.run(
            ["sudo", "-n", "systemctl", "--version"],
            capture_output=True, text=True, timeout=5,
        )
        return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def switch_php(target):
    if not can_sudo_nopasswd():
        return False, "needs_sudo"
    try:
        r = subprocess.run(
            ["sudo", "-n", "update-alternatives", "--set", "php", target],
            capture_output=True, text=True, timeout=15,
        )
        return r.returncode == 0, (r.stderr.strip() or None)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        return False, "no_sudo"


def detect_project_php(directory=None):
    start = Path(directory or os.getcwd()).resolve()

    d = start
    while True:
        f = d / ".php-version"
        if f.exists():
            return f.read_text().strip()
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
                m = re.search(r"(\d+\.\d+)", req)
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
             "--icon=dialog-information"],
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
    sapis = []
    if shutil.which(f"php{version}"):
        sapis.append("cli")
    if Path(f"/usr/sbin/php-fpm{version}").exists():
        sapis.append("fpm")
    if Path(f"/etc/apache2/mods-available/php{version}.conf").exists():
        sapis.append("apache2")
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
    out, code = run([f"php{version}", "-m"])
    if code != 0:
        return None
    return any(line.strip().lower() == "xdebug" for line in out.splitlines())


def get_ini_path(version):
    out, code = run([f"php{version}", "--ini"])
    if code != 0:
        return None
    for line in out.splitlines():
        if "Loaded Configuration File" in line and ":" in line:
            return line.split(":", 1)[1].strip()
    return None


def reload_fpm(version):
    if not can_sudo_systemctl():
        return False, "needs_sudo"
    try:
        r = subprocess.run(
            ["sudo", "-n", "systemctl", "restart", f"php{version}-fpm"],
            capture_output=True, text=True, timeout=15,
        )
        return r.returncode == 0, (r.stderr.strip() or None)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        return False, "no_sudo"


# ---------- window mode ----------

class PHPSwitcherWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="phpvm")
        self.set_default_size(720, 520)
        self.set_icon_name("dialog-information")

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(12)
        outer.set_margin_bottom(12)
        outer.set_margin_start(12)
        outer.set_margin_end(12)
        self.add(outer)

        self.header_label = Gtk.Label(xalign=0)
        self.header_label.set_use_markup(True)
        outer.pack_start(self.header_label, False, False, 0)

        self.project_label = Gtk.Label(xalign=0)
        self.project_label.set_line_wrap(True)
        outer.pack_start(self.project_label, False, False, 0)

        outer.pack_start(Gtk.Separator(), False, False, 4)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        outer.pack_start(scroll, True, True, 0)

        self.list_box = Gtk.ListBox()
        self.list_box.set_selection_mode(Gtk.SelectionMode.NONE)
        scroll.add(self.list_box)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        outer.pack_start(actions, False, False, 0)

        refresh_btn = Gtk.Button(label="Refresh")
        refresh_btn.connect("clicked", lambda _: self.refresh())
        actions.pack_start(refresh_btn, False, False, 0)

        auto_btn = Gtk.Button(label="Auto-detect from project")
        auto_btn.connect("clicked", self._on_auto)
        actions.pack_start(auto_btn, False, False, 0)

        folder_btn = Gtk.Button(label="Pick folder…")
        folder_btn.connect("clicked", self._on_folder)
        actions.pack_start(folder_btn, False, False, 0)

        self.refresh()

    def refresh(self):
        for child in self.list_box.get_children():
            self.list_box.remove(child)

        current = get_current()
        php_v_out, _ = run(["php", "--version"])
        php_v_line = php_v_out.splitlines()[0] if php_v_out else ""

        if current:
            self.header_label.set_markup(
                f'<big><b>Active:</b> '
                f'<span foreground="#2da44e">{GLib.markup_escape_text(Path(current).name)}</span>'
                f'</big>\n<small>{GLib.markup_escape_text(php_v_line)}</small>'
            )
        else:
            self.header_label.set_markup("<big><b>Active:</b> <i>unknown</i></big>")

        proj = detect_project_php()
        if proj:
            self.project_label.set_markup(
                f"<b>Project requires:</b> PHP {GLib.markup_escape_text(proj)}  "
                f'<i><small>(cwd: {GLib.markup_escape_text(os.getcwd())})</small></i>'
            )
        else:
            self.project_label.set_markup(
                "<i>No .php-version or composer.json detected in current directory.</i>"
            )

        for v in get_versions():
            self.list_box.add(self._build_row(v, current))

        self.list_box.show_all()

    def _build_row(self, v, current):
        ver = version_num(v)
        active = (v == current)

        row = Gtk.ListBoxRow()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        box.set_margin_top(6)
        box.set_margin_bottom(6)
        box.set_margin_start(8)
        box.set_margin_end(8)
        row.add(box)

        name_label = Gtk.Label(xalign=0)
        name_label.set_use_markup(True)
        if active:
            name_label.set_markup(
                f'<span foreground="#2da44e"><b>● {GLib.markup_escape_text(Path(v).name)}</b></span>'
            )
        else:
            name_label.set_markup(f"  {GLib.markup_escape_text(Path(v).name)}")
        name_label.set_size_request(140, -1)
        box.pack_start(name_label, False, False, 0)

        badges = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        for sapi in get_sapis(ver):
            badges.pack_start(self._badge(sapi, "#0969da"), False, False, 0)

        if get_xdebug_status(ver):
            badges.pack_start(self._badge("xdebug", "#bf8700"), False, False, 0)

        fpm = get_fpm_status(ver)
        if fpm == "active":
            badges.pack_start(self._badge("fpm: running", "#2da44e"), False, False, 0)
        elif fpm in ("inactive", "failed"):
            badges.pack_start(self._badge(f"fpm: {fpm}", "#6e7781"), False, False, 0)

        eol = is_eol(ver)
        if eol is True:
            badges.pack_start(self._badge("EOL", "#cf222e"), False, False, 0)

        box.pack_start(badges, True, True, 0)

        if "fpm" in get_sapis(ver):
            reload_btn = Gtk.Button(label="Restart FPM")
            reload_btn.set_tooltip_text(f"sudo systemctl restart php{ver}-fpm")
            reload_btn.connect("clicked", self._on_reload_fpm, ver)
            box.pack_end(reload_btn, False, False, 0)

        switch_btn = Gtk.Button(label="Active" if active else "Switch")
        switch_btn.set_sensitive(not active)
        switch_btn.connect("clicked", self._on_switch, v)
        box.pack_end(switch_btn, False, False, 0)

        ini = get_ini_path(ver)
        if ini:
            row.set_tooltip_text(f"php.ini: {ini}")

        return row

    def _badge(self, text, color):
        lbl = Gtk.Label()
        lbl.set_markup(
            f'<span size="x-small" background="{color}" foreground="white">'
            f' {GLib.markup_escape_text(text)} </span>'
        )
        return lbl

    def _on_switch(self, _btn, target):
        def worker():
            ok, err = switch_php(target)
            GLib.idle_add(self._post_switch, ok, Path(target).name, err)
        threading.Thread(target=worker, daemon=True).start()

    def _post_switch(self, ok, name, err):
        if ok:
            notify("phpvm", f"Switched to {name}")
        elif err == "needs_sudo":
            notify("phpvm",
                   "Passwordless sudo not configured for update-alternatives.",
                   urgent=True)
        else:
            notify("phpvm", f"Failed to switch to {name}", urgent=True)
        self.refresh()
        return False

    def _on_reload_fpm(self, _btn, ver):
        def worker():
            ok, err = reload_fpm(ver)
            GLib.idle_add(self._post_fpm, ok, ver, err)
        threading.Thread(target=worker, daemon=True).start()

    def _post_fpm(self, ok, ver, err):
        if ok:
            notify("phpvm", f"Restarted php{ver}-fpm")
        elif err == "needs_sudo":
            notify("phpvm",
                   f"Need a sudoers rule for: systemctl restart php{ver}-fpm",
                   urgent=True)
        else:
            notify("phpvm", f"Failed to restart php{ver}-fpm", urgent=True)
        self.refresh()
        return False

    def _on_auto(self, _btn):
        proj = detect_project_php()
        if not proj:
            notify("phpvm", "No .php-version or composer.json found")
            return
        target = next(
            (v for v in get_versions() if Path(v).name == f"php{proj}"), None
        )
        if not target:
            notify("phpvm", f"PHP {proj} required but not installed", urgent=True)
            return
        if target == get_current():
            notify("phpvm", f"Already on PHP {proj}")
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
            notify("phpvm", "No .php-version or composer.json in that folder")
            return
        target = next(
            (v for v in get_versions() if Path(v).name == f"php{proj}"), None
        )
        if not target:
            notify("phpvm", f"PHP {proj} required but not installed", urgent=True)
            return
        if target == get_current():
            notify("phpvm", f"Already on PHP {proj}")
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
                "dialog-information",
                IndicatorCategory.APPLICATION_STATUS
            )
            self.indicator.set_status(IndicatorStatus.ACTIVE)
            self.indicator.set_label(label, "PHP 8.88")
            self.indicator.set_menu(self.menu)
        else:
            print("Warning: AppIndicator3 not found, falling back to StatusIcon.")
            print("Install: sudo apt install gir1.2-ayatana-appindicator3-0.1")
            self.status_icon = Gtk.StatusIcon()
            self.status_icon.set_from_icon_name("dialog-information")
            self.status_icon.set_tooltip_text(label)
            self.status_icon.connect("popup-menu", self._status_icon_popup)

        GLib.timeout_add(REFRESH_MS, self._tick)

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
        self._refresh_label()
        self._build_menu()
        if ok:
            notify("phpvm", f"Switched to {name}")
        elif err == "needs_sudo":
            notify("phpvm",
                   "Passwordless sudo not configured.\n"
                   "Run install.sh or add a /etc/sudoers.d/phpvm rule.",
                   urgent=True)
        else:
            notify("phpvm", f"Failed to switch to {name}", urgent=True)
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
        win = PHPSwitcherWindow()
        win.show_all()

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
            self.indicator.set_label(label, "PHP 8.88")
        else:
            self.status_icon.set_tooltip_text(label)

    def _tick(self):
        self._refresh_label()
        return True


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    args = sys.argv[1:]
    mode = "tray"
    if "--window" in args or "-w" in args:
        mode = "window"
    elif "--help" in args or "-h" in args:
        print("Usage: phpvm-gui [--window|-w] [--help]")
        print("  (no args)   Run as system tray applet")
        print("  --window    Open the picker window directly (no tray)")
        return

    if mode == "window":
        win = PHPSwitcherWindow()
        win.connect("destroy", Gtk.main_quit)
        win.show_all()
    else:
        PHPSwitcherTray()
    Gtk.main()


if __name__ == "__main__":
    main()
