import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/settings/assistant_settings_section.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

import 'support/assistant_fakes.dart';

/// Holds the settings the way the settings screen does: a change shows at once.
class _Host extends StatefulWidget {
  const _Host({required this.service, required this.initial, required this.log});
  final FakeAssistantService service;
  final AppSettings initial;
  final List<AppSettings> log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late AppSettings settings = widget.initial;

  @override
  void initState() {
    super.initState();
    widget.service.provider = widget.initial.assistantProvider;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      child: AssistantSettingsSection(
        settings: settings,
        service: widget.service,
        apply: (change) async {
          final next = change(settings);
          widget.log.add(next);
          widget.service.provider = next.assistantProvider;
          setState(() => settings = next);
        },
      ),
    ),
  );
}

void main() {
  late FakeAssistantService service;
  late List<AppSettings> log;

  Future<void> pump(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
    Size size = const Size(800, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(service: service, initial: settings, log: log),
      ),
    );
  }

  setUp(() {
    service = FakeAssistantService(problem: 'Add an API key in the assistant settings.');
    log = [];
  });

  testWidgets('off by default: only the switch shows', (tester) async {
    await pump(tester);
    expect(find.text('Use the built-in assistant'), findsOneWidget);
    expect(find.text('API key'), findsNothing);
    expect(find.text('Provider'), findsNothing);
  });

  testWidgets('turning it on explains first; cancel leaves it off', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Turn on the built-in assistant?'), findsOneWidget);
    expect(find.textContaining('are sent to the AI service you choose'),
        findsOneWidget);
    expect(find.textContaining('not in backups'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(log, isEmpty);
    expect(find.text('API key'), findsNothing);

    // And it asks again the next time.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Turn on the built-in assistant?'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(log.last.assistantEnabled, isTrue);
    expect(find.text('API key'), findsOneWidget);
  });

  testWidgets('switching off needs no dialog', (tester) async {
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(log.last.assistantEnabled, isFalse);
  });

  testWidgets('the address field follows the provider', (tester) async {
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    expect(find.text('Address (optional)'), findsOneWidget);
    expect(find.textContaining("Anthropic's own address"), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<AssistantProviderKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI-compatible').last);
    await tester.pumpAndSettle();
    expect(log.last.assistantProvider, AssistantProviderKind.openAiCompatible);
    expect(find.text('Address'), findsOneWidget);
    expect(find.text('Address (optional)'), findsNothing);
  });

  testWidgets('address and model are saved when the field is left', (
    tester,
  ) async {
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    await tester.enterText(find.widgetWithText(TextField, 'Model'), ' my-model ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(log.last.assistantModel, 'my-model');
  });

  testWidgets('the key is saved, hidden and never shown again', (tester) async {
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    expect(find.text('No key saved'), findsOneWidget);
    final save = find.widgetWithText(FilledButton, 'Save key');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-secret-123');
    await tester.pump();
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'API key'),
    );
    expect(field.obscureText, isTrue);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(service.savedKeys, ['sk-secret-123']);
    expect(find.text('Key saved'), findsOneWidget);
    expect(find.textContaining('sk-secret-123'), findsNothing);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'API key'))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('the key can be removed', (tester) async {
    service.keySaved = true;
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    expect(find.text('Key saved'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Remove key'));
    await tester.pumpAndSettle();
    expect(service.clears, 1);
    expect(find.text('No key saved'), findsOneWidget);
  });

  testWidgets('the key state follows the selected provider', (tester) async {
    service.keySaved = true; // Anthropic's
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    expect(find.text('Key saved'), findsOneWidget);
    // A key typed for one provider is not carried over to the other.
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-ant');
    await tester.pump();

    await tester.tap(find.byType(DropdownButtonFormField<AssistantProviderKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI-compatible').last);
    await tester.pumpAndSettle();
    expect(find.text('No key saved'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'API key'))
          .controller!
          .text,
      isEmpty,
    );
    final remove = find.widgetWithText(OutlinedButton, 'Remove key');
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-oai');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save key'));
    await tester.pumpAndSettle();
    expect(service.savedKeys, ['sk-oai']);
    expect(service.savedFor, [AssistantProviderKind.openAiCompatible]);
  });

  testWidgets('a line under the address says where the key is sent', (
    tester,
  ) async {
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    expect(
      find.text('Your API key for this provider will be sent to '
          'api.anthropic.com.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Address (optional)'),
      'https://llm.example.org:8443/v1',
    );
    await tester.pump();
    expect(
      find.text('Your API key for this provider will be sent to '
          'llm.example.org.'),
      findsOneWidget,
    );
    // No address for an OpenAI-compatible service: nowhere to name.
    await tester.enterText(
      find.widgetWithText(TextField, 'Address (optional)'),
      '',
    );
    await tester.tap(find.byType(DropdownButtonFormField<AssistantProviderKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI-compatible').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('will be sent to'), findsNothing);
  });

  testWidgets('a storage failure is shown as the storage worded it', (
    tester,
  ) async {
    service.keyError = const SecureStorageUnavailableException(
      'The keyring is locked. Unlock it and try again.',
    );
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'k');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save key'));
    await tester.pumpAndSettle();
    expect(find.text('The keyring is locked. Unlock it and try again.'),
        findsOneWidget);
    expect(service.savedKeys, isEmpty);
    expect(service.hasApiKey, isFalse);
  });

  testWidgets('the status line shows the problem, then Ready', (tester) async {
    await pump(tester, settings: const AppSettings(assistantEnabled: true));
    expect(find.text('Add an API key in the assistant settings.'),
        findsOneWidget);
    service.problem = null;
    service.changed();
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('fits a 360 wide phone without overflow', (tester) async {
    await pump(
      tester,
      settings: const AppSettings(
        assistantEnabled: true,
        assistantProvider: AssistantProviderKind.openAiCompatible,
      ),
      size: const Size(360, 1400),
    );
    expect(tester.takeException(), isNull);
  });
}
