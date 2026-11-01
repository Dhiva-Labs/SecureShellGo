#!/usr/bin/env python3
"""Exits 0 if a window whose name contains NAME exists on $DISPLAY.

The same question as `xdotool search --name NAME`, for machines without
xdotool (the Flatpak builder image has Python and libX11 but no xdotool): it
walks the window tree through libX11 with ctypes and reads WM_NAME and
_NET_WM_NAME.

    tools/ci/x11-window.py <name>
"""
import ctypes
import ctypes.util
import sys
from ctypes import POINTER, byref, c_char_p, c_int, c_long, c_ubyte, c_uint, c_ulong, c_void_p

name = sys.argv[1].encode()
x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
Window = c_ulong
x11.XOpenDisplay.restype = c_void_p
x11.XOpenDisplay.argtypes = [c_char_p]
x11.XDefaultRootWindow.restype = Window
x11.XDefaultRootWindow.argtypes = [c_void_p]
x11.XQueryTree.argtypes = [c_void_p, Window, POINTER(Window), POINTER(Window), POINTER(POINTER(Window)), POINTER(c_uint)]
x11.XFetchName.argtypes = [c_void_p, Window, POINTER(c_char_p)]
x11.XInternAtom.restype = c_ulong
x11.XInternAtom.argtypes = [c_void_p, c_char_p, c_int]
x11.XGetWindowProperty.argtypes = [
    c_void_p, Window, c_ulong, c_long, c_long, c_int, c_ulong,
    POINTER(c_ulong), POINTER(c_int), POINTER(c_ulong), POINTER(c_ulong), POINTER(POINTER(c_ubyte)),
]

display = x11.XOpenDisplay(None)
if not display:
    sys.exit(2)
net_wm_name = x11.XInternAtom(display, b"_NET_WM_NAME", 0)
utf8_string = x11.XInternAtom(display, b"UTF8_STRING", 0)


def names(window):
    found = []
    wm_name = c_char_p()
    if x11.XFetchName(display, window, byref(wm_name)) and wm_name.value:
        found.append(wm_name.value)
    actual_type, actual_format = c_ulong(), c_int()
    count, after, data = c_ulong(), c_ulong(), POINTER(c_ubyte)()
    status = x11.XGetWindowProperty(
        display, window, net_wm_name, 0, 1024, 0, utf8_string,
        byref(actual_type), byref(actual_format), byref(count), byref(after), byref(data),
    )
    if status == 0 and data and count.value:
        found.append(ctypes.string_at(data, count.value))
    return found


def search(window):
    root, parent = Window(), Window()
    children, count = POINTER(Window)(), c_uint()
    if not x11.XQueryTree(display, window, byref(root), byref(parent), byref(children), byref(count)):
        return False
    for i in range(count.value):
        child = children[i]
        if any(name in n for n in names(child)) or search(child):
            return True
    return False


sys.exit(0 if search(x11.XDefaultRootWindow(display)) else 1)
