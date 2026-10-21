import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every translation carries every English string, with the same
/// placeholders — a missing key would fall back to English mid-screen, and a
/// mistyped placeholder would print `{count}` to the user.
void main() {
  final dir = Directory('lib/l10n');
  Map<String, dynamic> read(String code) =>
      jsonDecode(File('${dir.path}/app_$code.arb').readAsStringSync())
          as Map<String, dynamic>;

  final english = read('en');
  final keys = english.keys.where((k) => !k.startsWith('@')).toSet();
  final others = [
    for (final f in dir.listSync().whereType<File>())
      if (RegExp(r'app_(\w+)\.arb$').firstMatch(f.path) case final m?
          when m[1] != 'en')
        m[1]!,
  ]..sort();

  Set<String> placeholders(String text) => {
        for (final m in RegExp(r'\{(\w+)').allMatches(text)) m[1]!,
      };

  test('there are eight translations', () {
    expect(others, ['de', 'es', 'fr', 'ja', 'ko', 'pt', 'ru', 'zh']);
  });

  for (final code in others) {
    test('$code has every English string, with the same placeholders', () {
      final arb = read(code);
      expect(arb['@@locale'], code);
      final theirs = arb.keys.where((k) => !k.startsWith('@')).toSet();
      expect(keys.difference(theirs), isEmpty, reason: 'missing in $code');
      expect(theirs.difference(keys), isEmpty, reason: 'extra in $code');
      for (final key in keys) {
        final en = english[key] as String;
        final tr = arb[key] as String;
        expect(tr.trim(), isNotEmpty, reason: '$code.$key is empty');
        expect(placeholders(tr), placeholders(en),
            reason: '$code.$key placeholders differ');
      }
    });
  }

  test('every English string is described for translators', () {
    for (final key in keys) {
      expect(english['@$key'], isA<Map<String, dynamic>>(),
          reason: '@$key is missing');
    }
  });
}
