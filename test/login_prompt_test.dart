import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/login_prompt.dart';

const passwordHost = Host(
  id: 'h1',
  label: 'Build box',
  hostname: 'build.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
);

const bastion = Host(
  id: 'j1',
  label: 'Bastion',
  hostname: 'bastion.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.privateKey,
);

/// A keyboard-interactive round, the way a server would send it.
LoginChallenge round(
  List<(String, bool)> prompts, {
  String name = '',
  String instruction = '',
}) {
  return LoginChallenge.fromServer(
    name: name,
    instruction: instruction,
    prompts: [for (final (text, echo) in prompts) (text: text, echo: echo)],
  );
}

LoginChallenge hidden(String prompt) => round([(prompt, false)]);

/// Stands in for the person at the dialog: answers each prompt from a
/// script, in order, and records what they were shown.
class ScriptedPerson {
  ScriptedPerson(this.script);

  /// Each entry is the answers for one prompt, or null to press Cancel.
  final List<List<String>?> script;
  final List<LoginPrompt> seen = [];

  Future<List<String>?> answer(LoginPrompt prompt) async {
    seen.add(prompt);
    if (seen.length > script.length) {
      fail('asked ${seen.length} times, scripted for ${script.length}');
    }
    return script[seen.length - 1];
  }
}

void main() {
  group('the saved password', () {
    test('answers a plain password prompt without asking anyone', () async {
      final person = ScriptedPerson([]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      expect(await responder.respond(hidden('Password: ')), ['hunter2']);
      expect(person.seen, isEmpty);
      expect(responder.lastAnswerWasSavedPassword, isTrue);
      expect(responder.personAnswered, isFalse);
    });

    test('works with nobody there at all, as a reconnect needs', () async {
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
      );

      expect(
        await responder.respond(hidden("dev@build.example.com's password: ")),
        ['hunter2'],
      );
      expect(responder.unansweredPrompt, isNull);
    });

    test('is offered once; a second password prompt goes to the person',
        () async {
      final person = ScriptedPerson([
        ['typed-by-hand'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      expect(await responder.respond(hidden('Password: ')), ['hunter2']);
      expect(
        await responder.respond(hidden('(current) UNIX password: ')),
        ['typed-by-hand'],
      );
      expect(person.seen, hasLength(1));
      expect(responder.lastAnswerWasSavedPassword, isFalse,
          reason: 'the last answer came from the person');
    });

    test('is never offered once the server has refused it', () async {
      final person = ScriptedPerson([
        ['right-one'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'wrong-one',
        savedPasswordRejected: true,
        ask: person.answer,
      );

      expect(await responder.respond(hidden('Password: ')), ['right-one']);
      expect(person.seen.single.savedPasswordRejected, isTrue,
          reason: 'the dialog has to be able to say why it is asking');
    });

    test('is not used for a prompt that is echoed', () async {
      final person = ScriptedPerson([
        ['typed'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      expect(await responder.respond(round([('Password: ', true)])), [
        'typed',
      ]);
    });

    test('is not used for a round with more than one question', () async {
      final person = ScriptedPerson([
        ['pw', '123456'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      final answers = await responder.respond(
        round([('Password: ', false), ('Verification code: ', false)]),
      );
      expect(answers, ['pw', '123456']);
    });

    test('an empty saved password counts as none', () async {
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: '',
      );

      expect(await responder.respond(hidden('Password: ')), isNull);
      expect(responder.unansweredPrompt?.label, 'Password');
    });
  });

  group('one-time codes', () {
    test('password from the store, then the code from the person', () async {
      final person = ScriptedPerson([
        ['492039'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      expect(await responder.respond(hidden('Password: ')), ['hunter2']);
      expect(
        await responder.respond(hidden('Verification code: ')),
        ['492039'],
      );

      final asked = person.seen.single;
      expect(asked.host, passwordHost);
      expect(asked.jumpHostFor, isNull);
      expect(asked.fields.single.label, 'Verification code');
      expect(asked.fields.single.echo, isFalse);
      expect(responder.personAnswered, isTrue);
    });

    test('several rounds and several prompts arrive in order', () async {
      final person = ScriptedPerson([
        ['111111'],
        ['alpha', 'beta'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        ask: person.answer,
      );

      expect(await responder.respond(hidden('Token: ')), ['111111']);
      expect(
        await responder.respond(
          round(
            [('First answer: ', true), ('Second answer: ', false)],
            name: 'Security questions',
            instruction: 'Answer both.',
          ),
        ),
        ['alpha', 'beta'],
      );

      final second = person.seen.last;
      expect(second.challenge.name, 'Security questions');
      expect(second.challenge.instruction, 'Answer both.');
      expect([for (final f in second.fields) f.echo], [true, false]);
    });

    test('Duo\'s menu goes to the person even with a saved password',
        () async {
      final person = ScriptedPerson([
        ['1'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      final answers = await responder.respond(
        round([
          (
            'Duo two-factor login for dev\n\n'
                'Enter a passcode or select one of the following options:\n\n'
                ' 1. Duo Push to XXX-XXX-1234\n'
                ' 2. Phone call to XXX-XXX-1234\n\n'
                'Passcode or option (1-2): ',
            true,
          ),
        ]),
      );

      expect(answers, ['1']);
      final field = person.seen.single.fields.single;
      expect(field.label, 'Passcode or option (1-2)');
      expect(field.preamble, startsWith('Duo two-factor login for dev'));
      expect(field.preamble, contains(' 1. Duo Push'));
    });

    test('a jump host\'s prompt names the jump host and the target',
        () async {
      final person = ScriptedPerson([
        ['654321'],
      ]);
      final responder = KeyboardInteractiveResponder(
        host: bastion,
        jumpHostFor: passwordHost,
        ask: person.answer,
      );

      await responder.respond(hidden('Verification code: '));

      expect(person.seen.single.host, bastion);
      expect(person.seen.single.jumpHostFor, passwordHost);
    });

    test('a round with no questions is answered at once, and kept', () async {
      final person = ScriptedPerson([]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        ask: person.answer,
      );

      expect(
        await responder.respond(round([], instruction: 'Login request denied')),
        isEmpty,
      );
      expect(person.seen, isEmpty);
      expect(responder.notices, ['Login request denied']);
    });
  });

  group('when nobody answers', () {
    test('cancel declines the round and is remembered', () async {
      final person = ScriptedPerson([null]);
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
        ask: person.answer,
      );

      expect(await responder.respond(hidden('Verification code: ')), isNull);
      expect(responder.cancelled, isTrue);
      expect(responder.unansweredPrompt, isNull);
      expect(responder.personAnswered, isFalse);
    });

    test('with no person at all, a code prompt is declined and named',
        () async {
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        savedPassword: 'hunter2',
      );

      expect(await responder.respond(hidden('Password: ')), ['hunter2']);
      expect(await responder.respond(hidden('Verification code: ')), isNull);
      expect(responder.cancelled, isFalse);
      expect(responder.unansweredPrompt?.label, 'Verification code');
    });

    test('a prompt is told when the login is over without it', () async {
      final over = Completer<void>();
      LoginPrompt? shown;
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        withdrawn: over.future,
        ask: (prompt) async {
          shown = prompt;
          await prompt.withdrawn;
          return null;
        },
      );

      final answer = responder.respond(hidden('Verification code: '));
      await Future<void>.delayed(Duration.zero);
      expect(shown, isNotNull);
      over.complete();
      expect(await answer, isNull);
    });

    test('the wrong number of answers is a mistake, not a cancel', () async {
      final responder = KeyboardInteractiveResponder(
        host: passwordHost,
        ask: (_) async => ['one', 'two'],
      );

      expect(
        responder.respond(hidden('Verification code: ')),
        throwsArgumentError,
      );
    });
  });

  group('looksLikePasswordPrompt', () {
    for (final prompt in const [
      'Password: ',
      'password:',
      "dev@build.example.com's password: ",
      '(dev@build.example.com) Password: ',
      "dev@codeserver's password: ",
      'LDAP Password: ',
      'Password for dev@EXAMPLE.COM: ',
      'Passwort: ',
      'Mot de passe : ',
    ]) {
      test('yes: "$prompt"', () {
        expect(
          KeyboardInteractiveResponder.looksLikePasswordPrompt(prompt),
          isTrue,
        );
      });
    }

    for (final prompt in const [
      'Verification code: ',
      'Passcode or option (1-3): ',
      'Enter PASSCODE: ',
      "One-time password (OATH) for `dev': ",
      'Password + OTP: ',
      'New password: ',
      'Retype new password: ',
      'Token: ',
      '',
    ]) {
      test('no: "$prompt"', () {
        expect(
          KeyboardInteractiveResponder.looksLikePasswordPrompt(prompt),
          isFalse,
        );
      });
    }
  });

  group('cleanServerText', () {
    test('drops colour and title escapes whole', () {
      expect(
        cleanServerText('\x1B[1;31mWARNING\x1B[0m: \x1B]0;pwned\x07ok'),
        'WARNING: ok',
      );
    });

    test('drops control characters but keeps newlines and tabs', () {
      expect(cleanServerText('a\x00b\x07c\td\x7Fe\u009Bf\ng'), 'abc\tdef\ng');
    });

    test('drops bidirectional overrides', () {
      expect(cleanServerText('safe\u202Etxt.exe\u202C'), 'safetxt.exe');
      expect(cleanServerText('a\u2066b\u2069c\u200Fd'), 'abcd');
    });

    test('normalises line endings and trims blank edges', () {
      expect(
        cleanServerText('\r\n\r\nAuthorized use only.   \r\nBye\r\n\r\n'),
        'Authorized use only.\nBye',
      );
    });

    test('caps the length', () {
      final cleaned = cleanServerText('x' * 50, maxLength: 10);
      expect(cleaned, '${'x' * 10}…');
    });

    test('a challenge is cleaned field by field', () {
      final challenge = round(
        [('\x1B[32mVerification code:\x1B[0m ', false)],
        name: 'Two\x07-factor',
        instruction: 'Enter\x1B[K the code',
      );
      expect(challenge.name, 'Two-factor');
      expect(challenge.instruction, 'Enter the code');
      expect(challenge.fields.single.text, 'Verification code:');
      expect(challenge.fields.single.label, 'Verification code');
      expect(challenge.fields.single.preamble, isEmpty);
    });
  });
}
