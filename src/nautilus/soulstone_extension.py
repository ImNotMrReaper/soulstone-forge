"""Soul Stone right-click menu for GNOME Files (Nautilus 43+, nautilus-python 4.0).

Single source of truth for the Link / Unlink entries; install-soulstone-updates.sh copies it
to ~/.local/share/nautilus-python/extensions/. Do not also install Nautilus *scripts* for
this, or every entry shows up twice.

Menu rules (checked with cheap stat calls only, so right-click never stalls):
  * every selected item is a Soul Stone link  -> "Unlink from Soul Stone"
  * every selected item can be linked          -> "Link to Soul Stone"
  * anything else (mixed, protected, already on the card, not local) -> no entry
  * card offline -> the entry is shown greyed out with "(Soul Stone offline)"
The actual work, safety checks and notifications live in /usr/local/bin/soulstone-link.
"""
import os

import gi
gi.require_version('Nautilus', '4.0')
from gi.repository import GLib, GObject, Gio, Nautilus  # noqa: E402

LINK_TOOL = '/usr/local/bin/soulstone-link'
SD_MOUNT = '/mnt/sdcard'
LINKED_BASE = SD_MOUNT + '/Linked'
HOME = os.path.expanduser('~')
# Keep in sync with ss_link_target_ok in soulstone-link.
PROTECTED_TOP = {'.ssh', '.gnupg', '.config', '.local', '.cache', '.var', 'snap',
                 'Soul Stone', '.soulstone_conflicts'}
LOCKED_NOTES = os.path.join(HOME, 'Documents', 'Notes', 'Locked')


def _sd_dev():
    """st_dev of the mounted card, or None when it is not mounted."""
    try:
        if os.path.ismount(SD_MOUNT):
            return os.stat(SD_MOUNT).st_dev
    except OSError:
        pass
    return None


def _is_link(path):
    """True for a symlink made by soulstone-link (points into /mnt/sdcard/Linked)."""
    if not os.path.islink(path):
        return False
    target = os.path.join(os.path.dirname(path), os.readlink(path))
    return os.path.normpath(target).startswith(LINKED_BASE + '/')


def _is_locked_notes(path):
    """Pure string check: the locked notes vault is never touched, not even stat()ed."""
    p = os.path.abspath(path)
    return p == LOCKED_NOTES or p.startswith(LOCKED_NOTES + '/')


def _can_link(path, sd_dev):
    if _is_locked_notes(path):
        return False
    if os.path.islink(path) or not os.path.lexists(path):
        return False
    real = os.path.realpath(path)
    if _is_locked_notes(real) or not real.startswith(HOME + '/'):
        return False
    rel = os.path.relpath(real, HOME)
    if rel.split(os.sep, 1)[0] in PROTECTED_TOP:
        return False
    if any(part.startswith('.') for part in rel.split(os.sep)):
        return False  # hidden settings/app data stay on the internal drive
    try:
        if os.path.ismount(real):
            return False
        # Already on the card (e.g. inside ~/Documents overlay): nothing to move.
        if sd_dev is not None and os.lstat(real).st_dev == sd_dev:
            return False
    except OSError:
        return False
    return True


class SoulstoneMenuExtension(GObject.GObject, Nautilus.MenuProvider):
    def get_file_items(self, files):
        paths = []
        for f in files:
            if f.get_uri_scheme() != 'file':
                return []
            location = f.get_location()
            path = location.get_path() if location else None
            if not path:
                return []
            paths.append(path)
        if not paths:
            return []

        sd_dev = _sd_dev()
        online = sd_dev is not None
        count = f' {len(paths)} items' if len(paths) > 1 else ''

        if any(_is_locked_notes(p) for p in paths):
            return []
        if all(_is_link(p) for p in paths):
            action, label, tip, icon = ('unlink', f'Unlink{count} from Soul Stone',
                                        'Copy back to the internal drive, verify, then remove from Soul Stone',
                                        'drive-harddisk')
        elif all(_can_link(p, sd_dev) for p in paths) or (
                not online and all(_can_link(p, None) for p in paths)):
            action, label, tip, icon = ('link', f'Link{count} to Soul Stone',
                                        'Move to Soul Stone and leave a link in its place',
                                        'drive-removable-media')
        else:
            return []

        if not online:
            label += ' (Soul Stone offline)'
        item = Nautilus.MenuItem(name=f'Soulstone::{action}', label=label, tip=tip, icon=icon)
        item.set_property('sensitive', online)
        item.connect('activate', self._run, action, paths)
        return [item]

    def _run(self, _menu, action, paths):
        # Gio.Subprocess is reaped asynchronously, so Nautilus never blocks or leaks zombies.
        # soulstone-link shows its own success/failure notifications.
        try:
            proc = Gio.Subprocess.new([LINK_TOOL, action, *paths], Gio.SubprocessFlags.NONE)
            proc.wait_async(None, lambda p, res: p.wait_finish(res))
        except GLib.Error as err:
            n = Gio.Notification.new('Soul Stone')
            n.set_body(f'Could not start soulstone-link: {err.message}')
            app = Gio.Application.get_default()
            if app:
                app.send_notification('soulstone-link-error', n)
