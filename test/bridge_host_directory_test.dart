import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_host_directory.dart';

Host _host(
  String id,
  String label, {
  HostAiAccess access = HostAiAccess.readOnly,
  String? group,
}) => Host(
  id: id,
  label: label,
  hostname: '$label.example.com',
  port: 2222,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  group: group,
  aiAccess: access,
);

void main() {
  const directory = BridgeHostDirectory();

  test('only hosts with access on are listed', () {
    final hosts = [
      _host('aaaa1111', 'web'),
      _host('bbbb2222', 'db', access: HostAiAccess.off),
    ];
    expect(directory.list(hosts, showAddress: false).map((e) => e.name), [
      'web',
    ]);
  });

  test('askToChange hosts are listed and resolved like read-only ones', () {
    final hosts = [
      _host('aaaa1111', 'web', access: HostAiAccess.askToChange),
      _host('bbbb2222', 'db', access: HostAiAccess.off),
      _host('cccc3333', 'cache'),
    ];
    expect(directory.list(hosts, showAddress: false).map((e) => e.name), [
      'web',
      'cache',
    ]);
    expect(directory.resolve(hosts, 'web')!.id, 'aaaa1111');
    expect(directory.resolve(hosts, 'db'), isNull);
  });

  test('without showAddress only the name and group go out', () {
    final entry = directory.list([
      _host('aaaa1111', 'web', group: 'prod'),
    ], showAddress: false).single;
    expect(entry.toJson(), {'name': 'web', 'group': 'prod'});
  });

  test('with showAddress the hostname, port and username are added', () {
    final entry = directory.list([
      _host('aaaa1111', 'web'),
    ], showAddress: true).single;
    expect(entry.toJson(), {
      'name': 'web',
      'hostname': 'web.example.com',
      'port': 2222,
      'username': 'dev',
    });
  });

  test('a blank group is left out', () {
    final entry = directory.list([
      _host('aaaa1111', 'web', group: '  '),
    ], showAddress: false).single;
    expect(entry.group, isNull);
  });

  test('duplicate labels get an id prefix', () {
    final hosts = [_host('aaaa1111', 'web'), _host('bbbb2222', 'web')];
    expect(directory.list(hosts, showAddress: false).map((e) => e.name), [
      'web#aaaa',
      'web#bbbb',
    ]);
  });

  test('a hidden host with the same label does not rename a visible one', () {
    final hosts = [
      _host('aaaa1111', 'web'),
      _host('bbbb2222', 'web', access: HostAiAccess.off),
    ];
    expect(directory.list(hosts, showAddress: false).map((e) => e.name), [
      'web',
    ]);
  });

  test('ids sharing their first four characters get a longer prefix', () {
    final hosts = [_host('abcd1111', 'web'), _host('abcd2222', 'web')];
    final names = directory.list(hosts, showAddress: false).map((e) => e.name);
    expect(names, ['web#abcd1', 'web#abcd2']);
    expect(directory.resolve(hosts, 'web#abcd1')!.id, 'abcd1111');
    expect(directory.resolve(hosts, 'web#abcd2')!.id, 'abcd2222');
    expect(directory.resolve(hosts, 'web#abcd'), isNull);
  });

  test('a generated name never lands on a label the user typed', () {
    final hosts = [
      _host('aaaa1111', 'web'),
      _host('bbbb2222', 'web'),
      _host('cccc3333', 'web#aaaa'),
    ];
    final names = directory
        .list(hosts, showAddress: false)
        .map((e) => e.name)
        .toList();
    expect(names.toSet(), hasLength(3));
    expect(names, contains('web#aaaa'));
    expect(directory.resolve(hosts, 'web#aaaa')!.id, 'cccc3333');
    final other = names.firstWhere((n) => n.startsWith('web#aaaa1'));
    expect(directory.resolve(hosts, other)!.id, 'aaaa1111');
  });

  test('every listed name resolves back to its own host', () {
    final hosts = [
      _host('aaaa1111', 'web'),
      _host('aaaa2222', 'web'),
      _host('bbbb1111', 'web'),
      _host('cccc1111', 'db'),
      _host('dddd1111', ''),
      _host('eeee1111', '  '),
    ];
    for (final entry in directory.named(hosts)) {
      expect(directory.resolve(hosts, entry.name), same(entry.host));
    }
  });

  test('resolve is exact and refuses hidden hosts', () {
    final hosts = [
      _host('aaaa1111', 'web'),
      _host('bbbb2222', 'db', access: HostAiAccess.off),
    ];
    expect(directory.resolve(hosts, 'web')!.id, 'aaaa1111');
    expect(directory.resolve(hosts, 'Web'), isNull);
    expect(directory.resolve(hosts, ' web'), isNull);
    expect(directory.resolve(hosts, 'db'), isNull);
    expect(directory.resolve(hosts, 'bbbb2222'), isNull);
    expect(directory.resolve(hosts, ''), isNull);
  });

  test('a duplicate label without its suffix resolves to nothing', () {
    final hosts = [_host('aaaa1111', 'web'), _host('bbbb2222', 'web')];
    expect(directory.resolve(hosts, 'web'), isNull);
  });

  test('two hosts with one label and one id stay apart', () {
    final hosts = [_host('same', 'web'), _host('same', 'web')];
    final names = directory.named(hosts).map((e) => e.name).toList();
    expect(names.toSet(), hasLength(2));
    for (final name in names) {
      expect(directory.resolve(hosts, name), isNotNull);
    }
  });
}
