import 'dart:convert';
import 'dart:typed_data';

/// A user certificate line for the key [publicKeyBlob], shaped exactly as
/// `ssh-keygen -s` lays one out, with a made-up CA signature.
///
/// Good for anything that reads a certificate rather than trusts it — the
/// host form, the parser's field handling — without shelling out to
/// `ssh-keygen` from inside a widget test. Only an ed25519 key is
/// supported, which is all those need.
String certificateLineFor(
  Uint8List publicKeyBlob, {
  String keyId = 'alice@example',
  List<String> principals = const ['dev'],
  DateTime? validAfter,
  DateTime? validBefore,
  bool host = false,
  String comment = 'alice@laptop',
  BigInt? validAfterSeconds,
  Map<String, String> criticalOptions = const {},
  List<String> extensions = const [
    'permit-X11-forwarding',
    'permit-agent-forwarding',
    'permit-port-forwarding',
    'permit-pty',
    'permit-user-rc',
  ],
}) {
  final out = BytesBuilder();
  void string(List<int> bytes) => out
    ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
    ..add(bytes);
  void uint64(BigInt value) {
    final data = ByteData(8)
      ..setUint32(0, (value >> 32).toInt())
      ..setUint32(4, (value & BigInt.from(0xffffffff)).toInt());
    out.add(data.buffer.asUint8List());
  }

  BigInt seconds(DateTime? time, {required bool end}) => time == null
      ? (end ? (BigInt.one << 64) - BigInt.one : BigInt.zero)
      : BigInt.from(time.millisecondsSinceEpoch ~/ 1000);

  // The certified key's fields are the plain blob's, after its type.
  final keyFields = publicKeyBlob.sublist(4 + 11);
  const type = 'ssh-ed25519-cert-v01@openssh.com';
  string(utf8.encode(type));
  string(List.filled(32, 7)); // nonce
  out.add(keyFields);
  uint64(BigInt.one); // serial
  out.add((ByteData(4)..setUint32(0, host ? 2 : 1)).buffer.asUint8List());
  string(utf8.encode(keyId));
  final packed = BytesBuilder();
  for (final principal in principals) {
    final bytes = utf8.encode(principal);
    packed
      ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
      ..add(bytes);
  }
  string(packed.toBytes());
  uint64(validAfterSeconds ?? seconds(validAfter, end: false));
  uint64(seconds(validBefore, end: true));
  // Each option's value is itself a string, as ssh-keygen writes it.
  final options = BytesBuilder();
  void packedString(BytesBuilder into, List<int> bytes) => into
    ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
    ..add(bytes);
  for (final MapEntry(:key, :value) in criticalOptions.entries) {
    packedString(options, utf8.encode(key));
    final inner = BytesBuilder();
    if (value.isNotEmpty) packedString(inner, utf8.encode(value));
    packedString(options, inner.toBytes());
  }
  string(options.toBytes());
  final permits = BytesBuilder();
  for (final name in extensions) {
    packedString(permits, utf8.encode(name));
    packedString(permits, const []);
  }
  string(permits.toBytes());
  string(const []); // reserved
  final ca = BytesBuilder();
  for (final part in [utf8.encode('ssh-ed25519'), List.filled(32, 3)]) {
    ca
      ..add((ByteData(4)..setUint32(0, part.length)).buffer.asUint8List())
      ..add(part);
  }
  string(ca.toBytes());
  string(List.filled(83, 1)); // signature
  return '$type ${base64.encode(out.toBytes())} $comment';
}
