import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'ssh_agent_client.dart';

/// Pageant's agent pipe on Windows, found and checked the way PuTTY's own
/// tools find and check it.
///
/// Pageant listens on `\\.\pipe\pageant.<user>.<hash>`. The hash is not a
/// secret, so anyone on the machine who can work it out can create a pipe
/// by that name first and wait for a client to hand it a signing request —
/// which is why PuTTY (`connect_to_named_pipe` in its Windows sources)
/// refuses a pipe whose owner is not the user it is running as. This does
/// the same, on the very handle it then talks over: the pipe's owner SID,
/// from `GetSecurityInfo`, must equal the SID of this process's user.
///
/// Every Win32 call here is synchronous, and a signature can wait on a
/// security-key touch for a minute, so each request runs in a helper
/// isolate with its own connection: open, check the owner, write, read,
/// close. Nothing blocks the UI thread.
///
/// Must only be used on Windows. Not exercised by the unit tests, which run
/// on Linux: those cover the name ([pageantPipeName], [pageantUserName])
/// and the order agents are tried in (`SshAgentClient.openWindowsAgent`).
class PageantPipe implements SshAgentConnection {
  PageantPipe._(this._name, this.path);

  /// The pipe name as Windows sees it: the user name in the ANSI code page,
  /// as PuTTY's `CreateFileA` call sends it.
  final Uint8List _name;

  /// For messages.
  final String path;

  /// Pageant's pipe, if Pageant is running as this user. Null when it is
  /// not running, when the name cannot be worked out, or when the pipe by
  /// that name belongs to someone else.
  static Future<PageantPipe?> find() async {
    final name = _ownPipeName();
    if (name == null) return null;
    final pipe = PageantPipe._(name, latin1.decode(name));
    try {
      // One connection to prove it is there and ours; each request then
      // makes and checks its own.
      await Isolate.run(() => _roundTrip(name, null));
      return pipe;
    } on SshAgentException {
      return null;
    }
  }

  @override
  Future<Uint8List> request(Uint8List payload) {
    final name = _name;
    final frame = SshAgentProtocol.frame(payload);
    return Isolate.run(() => _roundTrip(name, frame)).then((reply) => reply!);
  }

  @override
  Future<void> close() async {
    // Each request closed its own handle.
  }
}

/// `\\.\pipe\pageant.<user>.<hash>`, as PuTTY's `agent_named_pipe_name`
/// builds it: [protectedBlock] is "Pageant" and a NUL, zero-padded to
/// sixteen bytes and passed through `CryptProtectMemory` with
/// `CRYPTPROTECTMEMORY_CROSS_PROCESS`; the hash is SHA-256 over that block
/// as an SSH string (a four-byte big-endian length, then the bytes), in
/// lower-case hex.
Uint8List pageantPipeName({
  required List<int> userName,
  required Uint8List protectedBlock,
}) {
  final hashed = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, protectedBlock.length)).buffer.asUint8List())
    ..add(protectedBlock);
  final digest = sha256.convert(hashed.takeBytes()).toString();
  return Uint8List.fromList([
    ...ascii.encode(r'\\.\pipe\pageant.'),
    ...userName,
    ...ascii.encode('.$digest'),
  ]);
}

/// The user part of the pipe name from what Windows reports: PuTTY asks for
/// the user principal name first (`alice@corp.example`) and keeps what is
/// before the `@`, falling back to the plain logon name.
List<int> pageantUserName(List<int> principalOrLogonName) {
  final at = principalOrLogonName.indexOf(0x40);
  return at < 0
      ? principalOrLogonName
      : principalOrLogonName.sublist(0, at);
}

/// The block PuTTY passes to `CryptProtectMemory`: "Pageant", its NUL, and
/// zeros to a whole number of sixteen-byte blocks.
Uint8List pageantSuffixBlock() {
  const blockSize = 16;
  final text = ascii.encode('Pageant');
  final length = ((text.length + 1 + blockSize - 1) ~/ blockSize) * blockSize;
  return Uint8List(length)..setRange(0, text.length, text);
}

// ---- Win32 ---------------------------------------------------------------

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _openExisting = 3;
const int _invalidHandle = -1;
const int _tokenQuery = 0x0008;
const int _tokenUser = 1;
const int _seKernelObject = 6;
const int _ownerSecurityInformation = 0x00000001;
const int _nameUserPrincipal = 8;
const int _cryptProtectMemoryCrossProcess = 0x1;

/// This user's Pageant pipe name, or null when it cannot be worked out.
Uint8List? _ownPipeName() {
  try {
    final user = _userName();
    if (user == null || user.isEmpty) return null;
    final block = pageantSuffixBlock();
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final protect = crypt32.lookupFunction<
        Int32 Function(Pointer<Uint8>, Uint32, Uint32),
        int Function(Pointer<Uint8>, int, int)>('CryptProtectMemory');
    final buffer = calloc<Uint8>(block.length);
    try {
      buffer.asTypedList(block.length).setAll(0, block);
      if (protect(buffer, block.length, _cryptProtectMemoryCrossProcess) ==
          0) {
        return null;
      }
      return pageantPipeName(
        userName: user,
        protectedBlock: Uint8List.fromList(buffer.asTypedList(block.length)),
      );
    } finally {
      calloc.free(buffer);
    }
  } catch (_) {
    return null;
  }
}

/// PuTTY's `get_username`, ANSI: the principal name before its `@`, or
/// the logon name.
List<int>? _userName() {
  final size = calloc<Uint32>();
  try {
    try {
      final secur32 = DynamicLibrary.open('secur32.dll');
      final getUserNameEx = secur32.lookupFunction<
          Uint8 Function(Int32, Pointer<Uint8>, Pointer<Uint32>),
          int Function(int, Pointer<Uint8>, Pointer<Uint32>)>('GetUserNameExA');
      size.value = 0;
      getUserNameEx(_nameUserPrincipal, nullptr, size);
      if (size.value > 0) {
        final buffer = calloc<Uint8>(size.value + 1);
        try {
          if (getUserNameEx(_nameUserPrincipal, buffer, size) != 0) {
            return pageantUserName(_cString(buffer, size.value + 1));
          }
        } finally {
          calloc.free(buffer);
        }
      }
    } catch (_) {
      // No secur32 or no principal name: a local account. The logon name.
    }
    final advapi32 = DynamicLibrary.open('advapi32.dll');
    final getUserName = advapi32.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint32>),
        int Function(Pointer<Uint8>, Pointer<Uint32>)>('GetUserNameA');
    size.value = 257;
    final buffer = calloc<Uint8>(size.value);
    try {
      if (getUserName(buffer, size) == 0) return null;
      return _cString(buffer, 257);
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(size);
  }
}

List<int> _cString(Pointer<Uint8> buffer, int max) {
  final bytes = buffer.asTypedList(max);
  final end = bytes.indexOf(0);
  return List<int>.of(end < 0 ? bytes : bytes.sublist(0, end));
}

/// In a helper isolate: connects to [name], refuses it unless this user
/// owns it, and, given a [frame], sends it and returns the reply payload.
Uint8List? _roundTrip(Uint8List name, Uint8List? frame) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final advapi32 = DynamicLibrary.open('advapi32.dll');
  final createFile = kernel32.lookupFunction<
      IntPtr Function(Pointer<Uint8>, Uint32, Uint32, Pointer<Void>, Uint32,
          Uint32, IntPtr),
      int Function(Pointer<Uint8>, int, int, Pointer<Void>, int, int,
          int)>('CreateFileA');
  final waitNamedPipe = kernel32.lookupFunction<
      Int32 Function(Pointer<Uint8>, Uint32),
      int Function(Pointer<Uint8>, int)>('WaitNamedPipeA');
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  final path = calloc<Uint8>(name.length + 1);
  path.asTypedList(name.length).setAll(0, name);
  var handle = _invalidHandle;
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      handle = createFile(path, _genericRead | _genericWrite, 0, nullptr,
          _openExisting, 0, 0);
      if (handle != _invalidHandle) break;
      // Busy between one client and the next instance, or not there at
      // all; either way waiting briefly costs nothing.
      waitNamedPipe(path, 2000);
    }
    if (handle == _invalidHandle) {
      throw const SshAgentException(
        SshAgentErrorKind.noAgent,
        'Pageant is not running.',
      );
    }
    if (!_ownedByThisUser(handle, kernel32, advapi32)) {
      throw const SshAgentException(
        SshAgentErrorKind.noAgent,
        'Refused the Pageant pipe: it belongs to another user.',
      );
    }
    if (frame == null) return null;
    _writeAll(kernel32, handle, frame);
    final header = _readExactly(kernel32, handle, 4);
    final length = ByteData.sublistView(header).getUint32(0);
    if (length == 0 || length > SshAgentProtocol.maxFrameLength) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent sent a malformed reply.',
        details: 'Frame length $length.',
      );
    }
    return _readExactly(kernel32, handle, length);
  } finally {
    if (handle != _invalidHandle) closeHandle(handle);
    calloc.free(path);
  }
}

/// Whether the pipe behind [handle] is owned by the user this process runs
/// as: `GetSecurityInfo`'s owner SID against `GetTokenInformation`'s
/// `TokenUser`, compared with `EqualSid`.
bool _ownedByThisUser(
  int handle,
  DynamicLibrary kernel32,
  DynamicLibrary advapi32,
) {
  final getCurrentProcess = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final localFree = kernel32.lookupFunction<IntPtr Function(Pointer<Void>),
      int Function(Pointer<Void>)>('LocalFree');
  final openProcessToken = advapi32.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
      int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');
  final getTokenInformation = advapi32.lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int,
          Pointer<Uint32>)>('GetTokenInformation');
  final getSecurityInfo = advapi32.lookupFunction<
      Uint32 Function(
          IntPtr,
          Int32,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>),
      int Function(
          int,
          int,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>)>('GetSecurityInfo');
  final equalSid = advapi32.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)>('EqualSid');

  final token = calloc<IntPtr>();
  final needed = calloc<Uint32>();
  final owner = calloc<Pointer<Void>>();
  final descriptor = calloc<Pointer<Void>>();
  Pointer<Uint8> tokenUser = nullptr;
  try {
    if (openProcessToken(getCurrentProcess(), _tokenQuery, token) == 0) {
      return false;
    }
    try {
      getTokenInformation(token.value, _tokenUser, nullptr, 0, needed);
      if (needed.value == 0) return false;
      tokenUser = calloc<Uint8>(needed.value);
      if (getTokenInformation(token.value, _tokenUser, tokenUser.cast(),
              needed.value, needed) ==
          0) {
        return false;
      }
    } finally {
      closeHandle(token.value);
    }
    // TOKEN_USER starts with SID_AND_ATTRIBUTES, which starts with the SID.
    final userSid = tokenUser.cast<Pointer<Void>>().value;

    if (getSecurityInfo(handle, _seKernelObject, _ownerSecurityInformation,
            owner, nullptr, nullptr, nullptr, descriptor) !=
        0) {
      return false;
    }
    try {
      return owner.value != nullptr && equalSid(owner.value, userSid) != 0;
    } finally {
      localFree(descriptor.value);
    }
  } finally {
    if (tokenUser != nullptr) calloc.free(tokenUser);
    calloc.free(token);
    calloc.free(needed);
    calloc.free(owner);
    calloc.free(descriptor);
  }
}

void _writeAll(DynamicLibrary kernel32, int handle, Uint8List bytes) {
  final writeFile = kernel32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>,
          Pointer<Void>),
      int Function(
          int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
  final buffer = calloc<Uint8>(bytes.length);
  final written = calloc<Uint32>();
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      if (writeFile(handle, buffer + offset, bytes.length - offset, written,
                  nullptr) ==
              0 ||
          written.value == 0) {
        throw const SshAgentException(
          SshAgentErrorKind.protocol,
          'The connection to Pageant failed.',
        );
      }
      offset += written.value;
    }
  } finally {
    calloc.free(buffer);
    calloc.free(written);
  }
}

Uint8List _readExactly(DynamicLibrary kernel32, int handle, int count) {
  final readFile = kernel32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>,
          Pointer<Void>),
      int Function(
          int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
  final buffer = calloc<Uint8>(count);
  final read = calloc<Uint32>();
  try {
    var offset = 0;
    while (offset < count) {
      if (readFile(handle, buffer + offset, count - offset, read, nullptr) ==
              0 ||
          read.value == 0) {
        throw const SshAgentException(
          SshAgentErrorKind.protocol,
          'Pageant closed the pipe before replying.',
        );
      }
      offset += read.value;
    }
    return Uint8List.fromList(buffer.asTypedList(count));
  } finally {
    calloc.free(buffer);
    calloc.free(read);
  }
}
