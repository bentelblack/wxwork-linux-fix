#!/usr/bin/env python3
import ctypes as C
import select
import signal
import sys

WXWORK_INSTANCE = 'wxwork.exe'
WXWORK_CLASS = 'com.qq.weixin.work.deepin'
ROOT_SUBSTRUCTURE_NOTIFY = 1 << 19
STRUCTURE_NOTIFY = 1 << 17
PROPERTY_CHANGE = 1 << 22
CW_OVERRIDE_REDIRECT = 1 << 9
IS_VIEWABLE = 2


def matches_wxwork(name, class_name):
    return name == WXWORK_INSTANCE and class_name == WXWORK_CLASS


def is_button_strip(width, height, parent_width, parent_height, override_redirect,
                    is_transient, parent_is_wxwork):
    return (override_redirect and is_transient and parent_is_wxwork
            and width == parent_width and 24 <= height <= 40
            and parent_height > height * 4)


class XWindowAttributes(C.Structure):
    _fields_ = [
        ('x', C.c_int), ('y', C.c_int), ('width', C.c_int), ('height', C.c_int),
        ('border_width', C.c_int), ('depth', C.c_int), ('visual', C.c_void_p),
        ('root', C.c_ulong), ('class', C.c_int), ('bit_gravity', C.c_int),
        ('win_gravity', C.c_int), ('backing_store', C.c_int),
        ('backing_planes', C.c_ulong), ('backing_pixel', C.c_ulong),
        ('save_under', C.c_int), ('colormap', C.c_ulong),
        ('map_installed', C.c_int), ('map_state', C.c_int),
        ('all_event_masks', C.c_long), ('your_event_mask', C.c_long),
        ('do_not_propagate_mask', C.c_long), ('override_redirect', C.c_int),
        ('screen', C.c_void_p),
    ]


class XClassHint(C.Structure):
    _fields_ = [('res_name', C.c_void_p), ('res_class', C.c_void_p)]


class XAnyEvent(C.Structure):
    _fields_ = [
        ('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
        ('display', C.c_void_p), ('window', C.c_ulong),
    ]


class XCreateWindowEvent(C.Structure):
    _fields_ = [
        ('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
        ('display', C.c_void_p), ('parent', C.c_ulong), ('window', C.c_ulong),
        ('x', C.c_int), ('y', C.c_int), ('width', C.c_int), ('height', C.c_int),
        ('border_width', C.c_int), ('override_redirect', C.c_int),
    ]


class XConfigureEvent(C.Structure):
    _fields_ = [
        ('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
        ('display', C.c_void_p), ('event', C.c_ulong), ('window', C.c_ulong),
        ('x', C.c_int), ('y', C.c_int), ('width', C.c_int), ('height', C.c_int),
        ('border_width', C.c_int), ('above', C.c_ulong), ('override_redirect', C.c_int),
    ]


class XMapEvent(C.Structure):
    _fields_ = [
        ('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
        ('display', C.c_void_p), ('event', C.c_ulong), ('window', C.c_ulong),
        ('override_redirect', C.c_int),
    ]


class XDestroyEvent(C.Structure):
    _fields_ = [
        ('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
        ('display', C.c_void_p), ('event', C.c_ulong), ('window', C.c_ulong),
    ]


class XPropertyEvent(C.Structure):
    _fields_ = [
        ('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
        ('display', C.c_void_p), ('window', C.c_ulong), ('atom', C.c_ulong),
        ('time', C.c_ulong), ('state', C.c_int),
    ]


class XEvent(C.Union):
    _fields_ = [
        ('type', C.c_int), ('any', XAnyEvent), ('create', XCreateWindowEvent),
        ('configure', XConfigureEvent), ('map', XMapEvent),
        ('destroy', XDestroyEvent), ('property', XPropertyEvent),
        ('pad', C.c_long * 24),
    ]


class XWindowChangesForAttributes(C.Structure):
    _fields_ = [
        ('background_pixmap', C.c_ulong), ('background_pixel', C.c_ulong),
        ('border_pixmap', C.c_ulong), ('border_pixel', C.c_ulong),
        ('bit_gravity', C.c_int), ('win_gravity', C.c_int),
        ('backing_store', C.c_int), ('backing_planes', C.c_ulong),
        ('backing_pixel', C.c_ulong), ('save_under', C.c_int),
        ('event_mask', C.c_long), ('do_not_propagate_mask', C.c_long),
        ('override_redirect', C.c_int), ('colormap', C.c_ulong),
        ('cursor', C.c_ulong),
    ]


class X11:
    def __init__(self):
        self.lib = C.CDLL('libX11.so.6')
        self._bind()
        self.error_handler = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)(
            lambda _display, _error: 0)
        self.lib.XSetErrorHandler.argtypes = [C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)]
        self.lib.XSetErrorHandler.restype = C.c_void_p
        self.lib.XSetErrorHandler(self.error_handler)
        self.display = self.lib.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError('cannot open X display')
        self.root = self.lib.XDefaultRootWindow(self.display)
        self.motif_atom = self.lib.XInternAtom(self.display, b'_MOTIF_WM_HINTS', 0)
        self.watched = set()

    def _bind(self):
        lib = self.lib
        lib.XOpenDisplay.argtypes = [C.c_char_p]
        lib.XOpenDisplay.restype = C.c_void_p
        lib.XCloseDisplay.argtypes = [C.c_void_p]
        lib.XDefaultRootWindow.argtypes = [C.c_void_p]
        lib.XDefaultRootWindow.restype = C.c_ulong
        lib.XConnectionNumber.argtypes = [C.c_void_p]
        lib.XConnectionNumber.restype = C.c_int
        lib.XSelectInput.argtypes = [C.c_void_p, C.c_ulong, C.c_long]
        lib.XNextEvent.argtypes = [C.c_void_p, C.POINTER(XEvent)]
        lib.XPending.argtypes = [C.c_void_p]
        lib.XPending.restype = C.c_int
        lib.XSync.argtypes = [C.c_void_p, C.c_int]
        lib.XGetWindowAttributes.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(XWindowAttributes)]
        lib.XGetWindowAttributes.restype = C.c_int
        lib.XGetClassHint.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(XClassHint)]
        lib.XGetClassHint.restype = C.c_int
        lib.XFree.argtypes = [C.c_void_p]
        lib.XGetTransientForHint.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]
        lib.XGetTransientForHint.restype = C.c_int
        lib.XChangeWindowAttributes.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong,
                                                C.POINTER(XWindowChangesForAttributes)]
        lib.XInternAtom.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
        lib.XInternAtom.restype = C.c_ulong
        lib.XChangeProperty.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong, C.c_ulong,
                                        C.c_int, C.c_int, C.c_void_p, C.c_int]
        lib.XUnmapWindow.argtypes = [C.c_void_p, C.c_ulong]
        lib.XMapWindow.argtypes = [C.c_void_p, C.c_ulong]
        lib.XQueryTree.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                                   C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_ulong)),
                                   C.POINTER(C.c_uint)]
        lib.XQueryTree.restype = C.c_int

    def close(self):
        if self.display:
            self.lib.XCloseDisplay(self.display)
            self.display = None

    def attributes(self, window):
        attrs = XWindowAttributes()
        if not self.lib.XGetWindowAttributes(self.display, window, C.byref(attrs)):
            return None
        return attrs

    def class_hint(self, window):
        hint = XClassHint()
        if not self.lib.XGetClassHint(self.display, window, C.byref(hint)):
            return None
        try:
            name = C.string_at(hint.res_name).decode(errors='replace') if hint.res_name else ''
            class_name = C.string_at(hint.res_class).decode(errors='replace') if hint.res_class else ''
            return name, class_name
        finally:
            if hint.res_name:
                self.lib.XFree(hint.res_name)
            if hint.res_class:
                self.lib.XFree(hint.res_class)

    def transient_parent(self, window):
        parent = C.c_ulong()
        if not self.lib.XGetTransientForHint(self.display, window, C.byref(parent)):
            return None
        return parent.value

    def children(self, window):
        root = C.c_ulong()
        parent = C.c_ulong()
        children = C.POINTER(C.c_ulong)()
        count = C.c_uint()
        if not self.lib.XQueryTree(self.display, window, C.byref(root), C.byref(parent),
                                   C.byref(children), C.byref(count)):
            return []
        try:
            return [children[i] for i in range(count.value)]
        finally:
            if children:
                self.lib.XFree(children)

    def may_be_button_strip(self, window):
        attrs = self.attributes(window)
        if not attrs:
            return False
        return 24 <= attrs.height <= 40 and attrs.width >= 500

    def watch(self, window):
        if window in self.watched or not self.may_be_button_strip(window):
            return
        self.watched.add(window)
        self.lib.XSelectInput(self.display, window, STRUCTURE_NOTIFY | PROPERTY_CHANGE)

    def main_window(self, window):
        attrs = self.attributes(window)
        hint = self.class_hint(window)
        return bool(attrs and not attrs.override_redirect and hint and
                    matches_wxwork(*hint) and attrs.height >= 100)

    def convert_strip(self, window):
        attrs = self.attributes(window)
        hint = self.class_hint(window)
        parent = self.transient_parent(window)
        if not attrs or attrs.map_state != IS_VIEWABLE or not hint or not matches_wxwork(*hint):
            return False
        if parent is None or not self.main_window(parent):
            return False
        parent_attrs = self.attributes(parent)
        if not parent_attrs or not is_button_strip(
                attrs.width, attrs.height, parent_attrs.width, parent_attrs.height,
                bool(attrs.override_redirect), True, True):
            return False

        self.lib.XSelectInput(self.display, window, STRUCTURE_NOTIFY | PROPERTY_CHANGE)
        self.lib.XUnmapWindow(self.display, window)
        self.lib.XSync(self.display, 0)
        changes = XWindowChangesForAttributes()
        changes.override_redirect = 0
        self.lib.XChangeWindowAttributes(self.display, window, CW_OVERRIDE_REDIRECT,
                                         C.byref(changes))
        hints = (C.c_ulong * 5)(2, 0, 0, 0, 0)
        self.lib.XChangeProperty(self.display, window, self.motif_atom, self.motif_atom,
                                 32, 0, C.cast(hints, C.c_void_p), 5)
        self.lib.XMapWindow(self.display, window)
        self.lib.XSync(self.display, 0)
        print(f'WXWork button window {window:#x} handed to the window manager', file=sys.stderr)
        return True

    def handle_event(self, event):
        if event.type == 16 and event.create.parent == self.root:
            window = event.create.window
            self.watch(window)
            self.convert_strip(window)
        elif event.type == 17:
            self.watched.discard(event.destroy.window)
        elif event.type == 19:
            window = event.map.window
            self.watch(window)
            self.convert_strip(window)
        elif event.type == 22:
            window = event.configure.window
            self.watch(window)
            self.convert_strip(window)
        elif event.type == 28:
            self.convert_strip(event.property.window)

    def run(self):
        self.lib.XSelectInput(self.display, self.root, ROOT_SUBSTRUCTURE_NOTIFY)
        for child in self.children(self.root):
            if self.may_be_button_strip(child):
                self.watch(child)
                self.convert_strip(child)

        fd = self.lib.XConnectionNumber(self.display)
        while True:
            select.select([fd], [], [])
            while self.lib.XPending(self.display):
                event = XEvent()
                self.lib.XNextEvent(self.display, C.byref(event))
                self.handle_event(event)


def main():
    try:
        x11 = X11()
    except (OSError, RuntimeError) as error:
        print(f'WXWork window stack helper: {error}', file=sys.stderr)
        return 0

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        x11.run()
    finally:
        x11.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
