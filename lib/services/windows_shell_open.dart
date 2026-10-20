import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opens [path] with its default handler on Windows, the way a double-click
/// in Explorer would.
///
/// This calls `ShellExecuteW` directly rather than going through
/// `cmd /c start "" <path>`, which is what it replaced. The file name of a
/// download comes from the server, and `cmd` parses its command line for
/// `&`, `|`, `^` and friends: Dart's `Process.run` only quotes an argument
/// that contains a space, tab or quote, so a server file named
/// `report&calc.exe` saved under a space-free profile path ran `calc` the
/// moment the user pressed Open. `ShellExecuteW` takes the path as one string
/// and never hands it to a command interpreter.
///
/// Returns false when the shell reports an error (no associated app, file
/// gone). Must only be called on Windows — `shell32.dll` exists nowhere else.
bool windowsShellOpen(String path) {
  final shellExecute = DynamicLibrary.open('shell32.dll').lookupFunction<
      IntPtr Function(
        IntPtr hwnd,
        Pointer<Utf16> operation,
        Pointer<Utf16> file,
        Pointer<Utf16> parameters,
        Pointer<Utf16> directory,
        Int32 showCommand,
      ),
      int Function(
        int hwnd,
        Pointer<Utf16> operation,
        Pointer<Utf16> file,
        Pointer<Utf16> parameters,
        Pointer<Utf16> directory,
        int showCommand,
      )>('ShellExecuteW');

  const swShowNormal = 1;
  final operation = 'open'.toNativeUtf16();
  final file = path.toNativeUtf16();
  try {
    // The return value is an HINSTANCE kept only for 16-bit compatibility:
    // anything above 32 is success, 32 and below is an error code.
    return shellExecute(0, operation, file, nullptr, nullptr, swShowNormal) >
        32;
  } finally {
    malloc.free(operation);
    malloc.free(file);
  }
}
