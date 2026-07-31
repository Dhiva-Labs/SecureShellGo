import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/host_grouping.dart';

void main() {
  Host host({
    required String id,
    String label = '',
    String hostname = 'example.com',
    String username = 'dev',
    int port = 22,
    String? group,
  }) {
    return Host(
      id: id,
      label: label,
      hostname: hostname,
      port: port,
      username: username,
      authMethod: SshAuthMethod.password,
      group: group,
    );
  }

  group('HostGrouping.buildSections', () {
    test('an empty host list produces no sections', () {
      expect(HostGrouping.buildSections(const []), isEmpty);
    });

    test('every host ungrouped produces one trailing Ungrouped section', () {
      final hosts = [host(id: 'a'), host(id: 'b')];
      final sections = HostGrouping.buildSections(hosts);

      expect(sections, hasLength(1));
      expect(sections.single.isUngrouped, isTrue);
      expect(sections.single.hosts.map((h) => h.id), ['a', 'b']);
    });

    test('named groups sort alphabetically, case-insensitively', () {
      final hosts = [
        host(id: 'a', group: 'zebra'),
        host(id: 'b', group: 'Apple'),
        host(id: 'c', group: 'mango'),
      ];
      final sections = HostGrouping.buildSections(hosts);

      expect(sections.map((s) => s.group), ['Apple', 'mango', 'zebra']);
    });

    test('Ungrouped always trails every named group', () {
      final hosts = [
        host(id: 'a'),
        host(id: 'b', group: 'Apple'),
      ];
      final sections = HostGrouping.buildSections(hosts);

      expect(sections.map((s) => s.group), ['Apple', null]);
    });

    test('a group with no hosts left after filtering does not appear', () {
      // buildSections only ever sees hosts that exist, so this is really
      // "a group is never rendered as an empty header" — there is no path
      // that hands it a group name with zero hosts.
      final hosts = [host(id: 'a', group: 'Work')];
      final sections = HostGrouping.buildSections(hosts, query: 'nomatch');
      expect(sections, isEmpty);
    });

    test('hosts inside a group keep the order they were given in', () {
      final hosts = [
        host(id: 'first', group: 'Work'),
        host(id: 'second', group: 'Work'),
        host(id: 'third', group: 'Work'),
      ];
      final sections = HostGrouping.buildSections(hosts);
      expect(
        sections.single.hosts.map((h) => h.id),
        ['first', 'second', 'third'],
      );
    });

    test('a blank query matches every host', () {
      final hosts = [host(id: 'a'), host(id: 'b', group: 'Work')];
      final sections = HostGrouping.buildSections(hosts, query: '   ');
      final total = sections.fold<int>(0, (n, s) => n + s.hosts.length);
      expect(total, 2);
    });

    test('query matches the display label, case-insensitively', () {
      final hosts = [host(id: 'a', label: 'Production Box')];
      final sections = HostGrouping.buildSections(hosts, query: 'production');
      expect(sections.single.hosts.single.id, 'a');
    });

    test('query matches hostname', () {
      final hosts = [host(id: 'a', hostname: 'db.internal.example.com')];
      final sections = HostGrouping.buildSections(hosts, query: 'db.internal');
      expect(sections.single.hosts.single.id, 'a');
    });

    test('query matches username', () {
      final hosts = [host(id: 'a', username: 'deploy')];
      final sections = HostGrouping.buildSections(hosts, query: 'deploy');
      expect(sections.single.hosts.single.id, 'a');
    });

    test('query filters hosts, not whole groups: a group with one hit shows '
        'only that host', () {
      final hosts = [
        host(id: 'hit', label: 'Staging box', group: 'Work'),
        host(id: 'miss', label: 'Other server', group: 'Work'),
      ];
      final sections = HostGrouping.buildSections(hosts, query: 'staging');

      expect(sections, hasLength(1));
      expect(sections.single.hosts.map((h) => h.id), ['hit']);
    });

    test('a query matching nothing produces no sections at all', () {
      final hosts = [host(id: 'a', group: 'Work'), host(id: 'b')];
      expect(HostGrouping.buildSections(hosts, query: 'nope-nothing'), isEmpty);
    });
  });

  group('HostSection', () {
    test('settingsKey is the group name for a named section', () {
      const section = HostSection(group: 'Work', hosts: []);
      expect(section.settingsKey, 'Work');
    });

    test('settingsKey is the ungrouped sentinel for the Ungrouped section', () {
      const section = HostSection(group: null, hosts: []);
      expect(section.settingsKey, ungroupedSectionKey);
      expect(section.isUngrouped, isTrue);
    });
  });
}
