import 'dart:convert';
import 'dart:typed_data';

/// The SOCKS5 wire format (RFC 1928), as much of it as a dynamic forward
/// needs and no more.
///
/// Parsing and encoding live here, apart from the sockets, for the same
/// reason `host_key_policy.dart` lives apart from `ssh_service.dart`: this is
/// the part that is exactly specified by a document, so it is the part worth
/// pinning to golden bytes in a test rather than to a running proxy.
///
/// **What is deliberately not implemented.** Only the no-authentication
/// method (`0x00`) and only the `CONNECT` command. `BIND` and
/// `UDP ASSOCIATE` would each need the server to listen on the user's behalf
/// in ways `ssh -D` does not, and every authentication method other than
/// "none" would mean this app inventing, storing and checking a second set of
/// credentials for a proxy that is already only reachable from loopback. A
/// client that offers neither is refused politely — see
/// [socks5MethodSelection] — rather than left hanging.
class Socks5 {
  const Socks5._();

  static const int version = 0x05;

  static const int methodNoAuth = 0x00;

  /// `NO ACCEPTABLE METHODS`: the only honest answer to a client that will
  /// not speak unauthenticated to a loopback proxy.
  static const int methodNone = 0xFF;

  static const int commandConnect = 0x01;

  static const int addressIpv4 = 0x01;
  static const int addressDomain = 0x03;
  static const int addressIpv6 = 0x04;

  static const int replySucceeded = 0x00;
  static const int replyGeneralFailure = 0x01;
  static const int replyHostUnreachable = 0x04;
  static const int replyCommandNotSupported = 0x07;
  static const int replyAddressNotSupported = 0x08;

  /// The longest a request can be: header, a 255-byte domain with its length
  /// prefix, and the port. Nothing may make the proxy buffer more than this
  /// before it has decided what to do.
  static const int maxRequestBytes = 4 + 1 + 255 + 2;
}

/// A client that is not speaking SOCKS5.
class Socks5FormatException implements Exception {
  const Socks5FormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The client's opening greeting: the version and the methods it offers.
class Socks5Greeting {
  const Socks5Greeting(this.methods);

  final List<int> methods;

  bool get offersNoAuth => methods.contains(Socks5.methodNoAuth);

  /// Parses a complete greeting — `VER NMETHODS METHODS…`.
  factory Socks5Greeting.parse(List<int> bytes) {
    if (bytes.length < 2) {
      throw const Socks5FormatException('Truncated SOCKS greeting.');
    }
    if (bytes[0] != Socks5.version) {
      // SOCKS4 opens with 0x04 and is a different protocol, not an older
      // dialect of this one, so it cannot be answered with a SOCKS5 reply.
      throw Socks5FormatException(
        'Not a SOCKS5 client (version byte 0x${bytes[0].toRadixString(16)}).',
      );
    }
    final count = bytes[1];
    if (bytes.length < 2 + count) {
      throw const Socks5FormatException('Truncated SOCKS method list.');
    }
    return Socks5Greeting(List<int>.unmodifiable(bytes.sublist(2, 2 + count)));
  }
}

/// What the client asked for.
class Socks5Request {
  const Socks5Request({
    required this.command,
    required this.addressType,
    required this.host,
    required this.port,
  });

  final int command;
  final int addressType;

  /// The destination, already decoded: dotted-quad for IPv4, the name itself
  /// for a domain, and colon-separated hex groups for IPv6.
  final String host;

  final int port;

  bool get isConnect => command == Socks5.commandConnect;

  /// Parses a complete request — `VER CMD RSV ATYP DST.ADDR DST.PORT`.
  factory Socks5Request.parse(List<int> bytes) {
    if (bytes.length < 4) {
      throw const Socks5FormatException('Truncated SOCKS request.');
    }
    if (bytes[0] != Socks5.version) {
      throw const Socks5FormatException('Wrong version in SOCKS request.');
    }
    final command = bytes[1];
    final addressType = bytes[3];
    final addressLength = socks5AddressLength(
      addressType,
      bytes.length > 4 ? bytes[4] : 0,
    );
    if (bytes.length < 4 + addressLength + 2) {
      throw const Socks5FormatException('Truncated SOCKS address.');
    }

    final address = bytes.sublist(4, 4 + addressLength);
    final portOffset = 4 + addressLength;
    final port = (bytes[portOffset] << 8) | bytes[portOffset + 1];

    return Socks5Request(
      command: command,
      addressType: addressType,
      host: socks5DecodeAddress(addressType, address),
      port: port,
    );
  }
}

/// How many bytes of address follow the four-byte request header.
///
/// [firstByte] is only read for a domain name, where it is the length prefix
/// and therefore part of the address itself. Split out from
/// [Socks5Request.parse] because the proxy has to know how much to read off
/// the socket *before* it has a complete request to parse.
int socks5AddressLength(int addressType, int firstByte) {
  switch (addressType) {
    case Socks5.addressIpv4:
      return 4;
    case Socks5.addressDomain:
      return 1 + firstByte;
    case Socks5.addressIpv6:
      return 16;
    default:
      throw Socks5FormatException(
        'Unsupported SOCKS address type 0x${addressType.toRadixString(16)}.',
      );
  }
}

/// Turns the raw address field into something [SSHClient.forwardLocal] can
/// dial.
///
/// The IPv6 form is written out in full — eight four-digit groups, no `::`
/// compression — because the only consumer is a `direct-tcpip` channel
/// request, where the address is an opaque string the *server* resolves.
/// Producing the canonical short form (RFC 5952) would be work in aid of
/// nobody reading it.
String socks5DecodeAddress(int addressType, List<int> address) {
  switch (addressType) {
    case Socks5.addressIpv4:
      return address.join('.');
    case Socks5.addressDomain:
      // The length prefix is part of what was read; drop it here.
      return utf8.decode(address.sublist(1), allowMalformed: true);
    case Socks5.addressIpv6:
      final groups = <String>[];
      for (var i = 0; i < 16; i += 2) {
        final value = (address[i] << 8) | address[i + 1];
        groups.add(value.toRadixString(16).padLeft(4, '0'));
      }
      return groups.join(':');
    default:
      throw Socks5FormatException(
        'Unsupported SOCKS address type 0x${addressType.toRadixString(16)}.',
      );
  }
}

/// The two-byte answer to a greeting: [Socks5.methodNoAuth] to proceed, or
/// [Socks5.methodNone] to refuse. A refusal is a complete, legal reply — the
/// client is expected to close after reading it, and we close too.
Uint8List socks5MethodSelection(int method) =>
    Uint8List.fromList([Socks5.version, method]);

/// A reply to a `CONNECT`.
///
/// `BND.ADDR`/`BND.PORT` are reported as `0.0.0.0:0`. They are meant to be
/// the address the proxy used towards the destination, and this proxy does
/// not have one: the connection is opened by the SSH server, out of an
/// interface this device cannot see and has no business guessing at. Every
/// client that only wants a byte stream (curl, browsers, `git`) ignores the
/// field; the ones that need a real bound address need `BIND`, which is not
/// supported here anyway.
Uint8List socks5Reply(int reply) => Uint8List.fromList([
      Socks5.version,
      reply,
      0x00,
      Socks5.addressIpv4,
      0, 0, 0, 0, // BND.ADDR
      0, 0, // BND.PORT
    ]);
