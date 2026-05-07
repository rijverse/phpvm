#!/usr/bin/env python3
"""phpvm system tray GUI — requires python3-gi, GTK3, and AppIndicator3.

    sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatana-appindicator3-0.1
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
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


def switch_php(target):
    _, code = run(["sudo", "update-alternatives", "--set", "php", target])
    return code == 0


def detect_project_php(directory=None):
    d = Path(directory or os.getcwd()).resolve()
    while d != d.parent:
        f = d / ".php-version"
        if f.exists():
            return f.read_text().strip()
        d = d.parent

    composer = Path(directory or os.getcwd()) / "composer.json"
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
        return version_label(current) if current else "PHP ?"

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

        tui_item = Gtk.MenuItem(label="Open Terminal UI")
        tui_item.connect("activate", self._on_tui)
        self.menu.append(tui_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _: Gtk.main_quit())
        self.menu.append(quit_item)

        self.menu.show_all()

    def _on_select(self, _widget, target):
        def run():
            ok = switch_php(target)
            name = Path(target).name
            GLib.idle_add(self._post_switch, ok, name)
        threading.Thread(target=run, daemon=True).start()

    def _post_switch(self, ok, name):
        self._refresh_label()
        self._build_menu()
        if ok:
            notify("phpvm", f"Switched to {name}")
        else:
            notify("phpvm", f"Failed to switch to {name}", urgent=True)
        return False

    def _on_auto(self, _widget, directory=None):
        proj = detect_project_php(directory)
        if not proj:
            notify("phpvm", "No .php-version or composer.json found")
            return

        versions = get_versions()
        target = next((v for v in versions if Path(v).name in (f"php{proj}", proj)), None)

        if not target:
            notify("phpvm", f"PHP {proj} required but not installed", urgent=True)
            return

        if target == get_current():
            notify("phpvm", f"Already on PHP {proj}")
            return

        def run():
            ok = switch_php(target)
            GLib.idle_add(self._post_switch, ok, Path(target).name)
        threading.Thread(target=run, daemon=True).start()

    def _on_auto_folder(self, _widget):
        dialog = Gtk.FileChooserDialog(
            title="Select project folder",
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OPEN, Gtk.ResponseType.OK,
        )
        if dialog.run() == Gtk.ResponseType.OK:
            folder = dialog.get_filename()
            dialog.destroy()
            self._on_auto(None, directory=folder)
        else:
            dialog.destroy()

    def _on_tui(self, _widget):
        terminals = [
            ["gnome-terminal", "--", "phpvm"],
            ["xterm", "-e", "phpvm"],
            ["konsole", "-e", "phpvm"],
            ["xfce4-terminal", "-e", "phpvm"],
            ["x-terminal-emulator", "-e", "phpvm"],
        ]
        for cmd in terminals:
            if subprocess.run(["which", cmd[0]], capture_output=True).returncode == 0:
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
    PHPSwitcherTray()
    Gtk.main()


if __name__ == "__main__":
    main()
