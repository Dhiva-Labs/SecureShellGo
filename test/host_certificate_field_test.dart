import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/widgets/host_certificate_field.dart';

import 'support/certificate_fixture.dart';

/// What the certificate row says about restrictions a certificate carries:
/// the parts `ssh-keygen -L` shows that change what signing in with it
/// does, or whether it works at all.
void main() {
  final key = _ed25519Blob();

  Future<void> show(WidgetTester tester, String line) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Form(
            child: HostCertificateField(
              certificate: line,
              onChanged: (_) {},
              deviceStorage: _NoStorage(),
              username: 'dev',
              now: () => DateTime.utc(2026, 6, 1),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('a certificate that names no users is not "any user"',
      (tester) async {
    await show(tester, certificateLineFor(key, principals: const []));
    expect(find.textContaining('any user'), findsNothing);
    expect(find.textContaining('(none)'), findsOneWidget);
    expect(find.textContaining('names no users'), findsOneWidget);
    expect(find.textContaining('TrustedUserCAKeys'), findsOneWidget);
  });

  testWidgets('a forced command and a source address are shown and warned '
      'about', (tester) async {
    await show(
      tester,
      certificateLineFor(key, criticalOptions: {
        'force-command': '/usr/bin/backup',
        'source-address': '10.0.0.0/8,192.168.1.5',
      }),
    );
    expect(
      find.textContaining('force-command=/usr/bin/backup'),
      findsOneWidget,
    );
    expect(find.textContaining('runs "/usr/bin/backup" instead of a shell'),
        findsOneWidget);
    expect(find.textContaining('Only accepted from 10.0.0.0/8, 192.168.1.5'),
        findsOneWidget);
  });

  testWidgets('what it permits is listed, and an unknown option warned about',
      (tester) async {
    await show(
      tester,
      certificateLineFor(
        key,
        extensions: const ['permit-pty'],
        criticalOptions: {'made-up-option': ''},
      ),
    );
    expect(find.textContaining('permit-pty'), findsOneWidget);
    expect(find.textContaining('permit-agent-forwarding'), findsNothing);
    expect(find.textContaining('OpenSSH does not know (made-up-option)'),
        findsOneWidget);
  });

  testWidgets('a start past year 9999 is shown as not valid yet',
      (tester) async {
    await show(
      tester,
      certificateLineFor(key, validAfterSeconds: (BigInt.one << 64) - BigInt.one),
    );
    expect(find.textContaining('Not valid until 9999'), findsOneWidget);
  });
}

Uint8List _ed25519Blob() {
  final out = BytesBuilder();
  for (final part in [utf8.encode('ssh-ed25519'), List.filled(32, 9)]) {
    out
      ..add((ByteData(4)..setUint32(0, part.length)).buffer.asUint8List())
      ..add(part);
  }
  return out.toBytes();
}

class _NoStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
