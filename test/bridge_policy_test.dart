import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';

Host _host(HostAiAccess access) => Host(
  id: 'id-1',
  label: 'web',
  hostname: 'web.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  aiAccess: access,
);

enum _HostCase { none, off, readOnly }

void main() {
  group('decideBridgeCall, every combination', () {
    // The expected answer, written out as the rule reads, independently of
    // the implementation's own if-chain.
    BridgeDecision expected({
      required bool enabled,
      required bool locked,
      required _HostCase hostCase,
      required bool hostRequired,
      required BridgeToolKind kind,
    }) {
      if (!enabled) return BridgeRefusals.bridgeOff;
      if (locked) return BridgeRefusals.appLocked;
      if (kind == BridgeToolKind.change) {
        return BridgeRefusals.changesNotAvailable;
      }
      if (hostCase == _HostCase.off) return BridgeRefusals.hostNotAvailable;
      if (hostCase == _HostCase.none && hostRequired) {
        return BridgeRefusals.hostNotAvailable;
      }
      return const BridgeAllow();
    }

    var count = 0;
    for (final enabled in [false, true]) {
      for (final locked in [false, true]) {
        for (final hostCase in _HostCase.values) {
          for (final hostRequired in [false, true]) {
            for (final kind in BridgeToolKind.values) {
              count++;
              test('enabled=$enabled locked=$locked host=${hostCase.name} '
                  'required=$hostRequired kind=${kind.name}', () {
                final host = switch (hostCase) {
                  _HostCase.none => null,
                  _HostCase.off => _host(HostAiAccess.off),
                  _HostCase.readOnly => _host(HostAiAccess.readOnly),
                };
                final decision = decideBridgeCall(
                  bridgeEnabled: enabled,
                  appLocked: locked,
                  host: host,
                  hostRequired: hostRequired,
                  kind: kind,
                );
                expect(
                  decision,
                  expected(
                    enabled: enabled,
                    locked: locked,
                    hostCase: hostCase,
                    hostRequired: hostRequired,
                    kind: kind,
                  ),
                );
              });
            }
          }
        }
      }
    }
    test('the table covers all ${2 * 2 * 3 * 2 * 2} cases', () {
      expect(count, 48);
    });
  });

  group('decideBridgeCall, the rules that matter most', () {
    test('only an enabled, unlocked read on an opened host is allowed', () {
      expect(
        decideBridgeCall(
          bridgeEnabled: true,
          appLocked: false,
          host: _host(HostAiAccess.readOnly),
          hostRequired: true,
          kind: BridgeToolKind.read,
        ),
        isA<BridgeAllow>(),
      );
    });

    test(
      'an unknown host and a host with access off are refused identically',
      () {
        final unknown =
            decideBridgeCall(
                  bridgeEnabled: true,
                  appLocked: false,
                  host: null,
                  hostRequired: true,
                  kind: BridgeToolKind.read,
                )
                as BridgeRefuse;
        final hidden =
            decideBridgeCall(
                  bridgeEnabled: true,
                  appLocked: false,
                  host: _host(HostAiAccess.off),
                  hostRequired: true,
                  kind: BridgeToolKind.read,
                )
                as BridgeRefuse;
        expect(hidden.code, unknown.code);
        expect(hidden.message, unknown.message);
        // Byte for byte, not merely equal after some normalisation.
        expect(hidden.code.codeUnits, unknown.code.codeUnits);
        expect(hidden.message.codeUnits, unknown.message.codeUnits);
        // And neither says anything about the host's existence or its name.
        expect(hidden.message, isNot(contains('web')));
        expect(hidden.message.toLowerCase(), isNot(contains('access')));
      },
    );

    test('a change tool is refused before the host is looked at', () {
      // Same answer whether the host exists, is hidden or is opened, so a
      // change tool cannot be used to probe for hosts either.
      final answers = {
        for (final host in [
          null,
          _host(HostAiAccess.off),
          _host(HostAiAccess.readOnly),
        ])
          decideBridgeCall(
            bridgeEnabled: true,
            appLocked: false,
            host: host,
            hostRequired: true,
            kind: BridgeToolKind.change,
          ),
      };
      expect(answers, {BridgeRefusals.changesNotAvailable});
      expect(BridgeRefusals.changesNotAvailable.code, 'changes_not_available');
    });

    test('a locked app says so, and nothing more', () {
      final decision =
          decideBridgeCall(
                bridgeEnabled: true,
                appLocked: true,
                host: null,
                hostRequired: true,
                kind: BridgeToolKind.change,
              )
              as BridgeRefuse;
      expect(decision.code, 'app_locked');
      expect(decision.message, startsWith('SecureShell Go is locked'));
    });

    test('a host passed to a tool that takes none is still held to access', () {
      expect(
        decideBridgeCall(
          bridgeEnabled: true,
          appLocked: false,
          host: _host(HostAiAccess.off),
          hostRequired: false,
          kind: BridgeToolKind.read,
        ),
        BridgeRefusals.hostNotAvailable,
      );
    });

    test('all refusal codes are distinct', () {
      final codes = {
        BridgeRefusals.bridgeOff.code,
        BridgeRefusals.appLocked.code,
        BridgeRefusals.changesNotAvailable.code,
        BridgeRefusals.hostNotAvailable.code,
      };
      expect(codes, hasLength(4));
    });
  });
}
