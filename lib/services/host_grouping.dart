import '../models/host.dart';

/// Sentinel key for the trailing Ungrouped section's entry in
/// [AppSettings.collapsedGroups] and any other per-group map keyed by name.
/// Safe as a stand-in for "no group": [Host.group] never persists an empty
/// string (see `Host.fromJson`), and group creation/rename both reject a
/// blank name before it ever reaches [HostStore].
const String ungroupedSectionKey = '';

/// One collapsible section of the saved-hosts list screen: a named group,
/// or the trailing Ungrouped bucket when [group] is null.
class HostSection {
  const HostSection({required this.group, required this.hosts});

  /// Null for the Ungrouped section.
  final String? group;
  final List<Host> hosts;

  bool get isUngrouped => group == null;

  /// The key this section's collapsed state is stored under in
  /// [AppSettings.collapsedGroups].
  String get settingsKey => group ?? ungroupedSectionKey;
}

/// Buckets a flat host list into the sections the list screen renders.
///
/// Pulled out of `host_list_screen.dart` so the grouping and search rules —
/// the part worth getting exactly right — can be unit-tested directly
/// against [Host] values, without pumping a widget tree.
class HostGrouping {
  const HostGrouping._();

  /// Named groups first (alphabetical, case-insensitive), then one trailing
  /// Ungrouped section — each dropped entirely once [query] leaves it with
  /// no hosts. Every host keeps the relative order [hosts] gave it (which is
  /// `HostStore`'s insertion order), so within a group that is still "the
  /// order hosts were added", same as the ungrouped list before this feature.
  ///
  /// [query] matches [Host.displayName], [Host.hostname], [Host.username]
  /// and [Host.target], case-insensitively; blank matches every host. This
  /// filters hosts, not whole groups, so a single hit still surfaces just
  /// that host under its own group's header.
  static List<HostSection> buildSections(
    List<Host> hosts, {
    String query = '',
  }) {
    final needle = query.trim().toLowerCase();
    final byGroup = <String, List<Host>>{};
    final ungrouped = <Host>[];

    for (final host in hosts) {
      if (needle.isNotEmpty && !_matches(host, needle)) continue;
      final group = host.group;
      if (group == null) {
        ungrouped.add(host);
      } else {
        byGroup.putIfAbsent(group, () => <Host>[]).add(host);
      }
    }

    final names = byGroup.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return [
      for (final name in names)
        HostSection(group: name, hosts: byGroup[name]!),
      if (ungrouped.isNotEmpty) HostSection(group: null, hosts: ungrouped),
    ];
  }

  static bool _matches(Host host, String needle) =>
      host.displayName.toLowerCase().contains(needle) ||
      host.hostname.toLowerCase().contains(needle) ||
      host.username.toLowerCase().contains(needle) ||
      host.target.toLowerCase().contains(needle);
}
