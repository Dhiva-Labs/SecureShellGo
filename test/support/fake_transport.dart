import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// The do-nothing end of a [SessionTransport], for a suite's own fake to
/// extend.
///
/// Every suite that needed a connection used to spell the whole interface
/// out in an `implements` fake of its own — ten copies — so one new member
/// meant ten edits in files nobody else was working in. Fakes extend this
/// now and override only what their suite looks at; a member added to the
/// interface gets its default here, once.
class FakeTransportBase extends SessionTransport {
  FakeTransportBase({Host? host}) : host = host ?? defaultHost;

  static const Host defaultHost = Host(
    id: 'h1',
    label: 'Test box',
    hostname: 'example.com',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
  );

  /// A password host as `dev`, for a fake standing in for one of several.
  static Host hostFor({
    String id = 'h1',
    String label = 'Test box',
    String hostname = 'example.com',
  }) =>
      Host(
        id: id,
        label: label,
        hostname: hostname,
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
      );

  @override
  final Host host;

  final Completer<void> _done = Completer<void>();

  var closeCount = 0;
  var pingCount = 0;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => closeCount > 0;

  /// The transport going away underneath the session. With an error it is a
  /// break; without one it is an orderly goodbye.
  void drop([Object? error]) {
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error);
    }
  }

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError('the shell needs a real SSH channel');

  @override
  Future<SftpClient> openSftp() =>
      throw UnimplementedError('tests inject a RemoteFileSystem instead');

  @override
  Future<SSHSession> execute(String command) =>
      throw UnimplementedError('exec needs a real SSH channel');

  @override
  Future<void> ping() async => pingCount++;

  @override
  void close() => closeCount++;
}
