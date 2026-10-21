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

  // The arguments an ICU message uses — `{name}`, and the `{count, plural,
  // …}` it branches on, with each branch's own text searched in turn. Branch
  // text is not an argument: `=1{There is…}` must not read as a placeholder
  // called "There", or no plural could ever match its translation.
  Set<String> placeholders(String text) {
    final names = <String>{};
    late int Function(int) message;
    int argument(int i) {
      final close = text.indexOf(RegExp('[,}]'), i);
      if (close < 0) return text.length;
      names.add(text.substring(i, close).trim());
      if (text[close] == '}') return close + 1;
      // `{name, plural, key{…} key{…}}`: skip to each branch's text.
      var j = text.indexOf(RegExp('[,}]'), close + 1);
      if (j < 0) return text.length;
      if (text[j] == '}') return j + 1;
      while (true) {
        final open = text.indexOf(RegExp('[{}]'), j + 1);
        if (open < 0) return text.length;
        if (text[open] == '}') return open + 1;
        j = message(open + 1);
      }
    }

    message = (i) {
      while (i < text.length) {
        if (text[i] == '}') return i;
        i = text[i] == '{' ? argument(i + 1) : i + 1;
      }
      return i;
    };
    message(0);
    return names;
  }

  test('placeholders are read past plural branch text', () {
    expect(
      placeholders('{count, plural, =1{There is one on {host}.} '
          'other{There are {count} on {host}.}}'),
      {'count', 'host'},
    );
    expect(placeholders('Sign in to {host}'), {'host'});
    expect(placeholders('{count, plural, other{Выбрано: {count}}}'), {'count'});
  });

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
