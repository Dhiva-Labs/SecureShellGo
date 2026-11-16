import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/services/assistant/assistant_conversation.dart';
import 'package:secure_shell_go/services/assistant/assistant_service.dart';
import 'package:secure_shell_go/services/assistant/assistant_types.dart';
import 'package:secure_shell_go/services/backup_payload.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

class _MemoryStorage implements SecureStorageBackend {
  final Map<String, String> data = {};
  bool failWrites = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) {
      throw const SecureStorageUnavailableException('Keyring locked.');
    }
    data[key] = value;
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);
}

class _IdleHost implements BridgeToolHost {
  @override
  List<BridgeToolSpec> get tools => const [];

  @override
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args, {
    BridgeCallToken? cancel,
  }) async => const BridgeToolResult('x');
}

void main() {
  group('settings', () {
    test('default off and empty, and a plain file saves exactly as before', () {
      const s = AppSettings();
      expect(s.assistantEnabled, isFalse);
      expect(s.assistantProvider, AssistantProviderKind.anthropic);
      expect(s.assistantBaseUrl, '');
      expect(s.assistantModel, '');
      expect(s.toJson().keys.where((k) => k.startsWith('assistant')), isEmpty);
      final back = AppSettings.fromJson(<String, dynamic>{});
      expect(back.assistantEnabled, isFalse);
      expect(back.assistantProvider, AssistantProviderKind.anthropic);
    });

    test('JSON round trip', () {
      const s = AppSettings(
        assistantEnabled: true,
        assistantProvider: AssistantProviderKind.openAiCompatible,
        assistantBaseUrl: 'https://api.openai.com/v1',
        assistantModel: 'gpt-x',
      );
      final back = AppSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.assistantEnabled, isTrue);
      expect(back.assistantProvider, AssistantProviderKind.openAiCompatible);
      expect(back.assistantBaseUrl, 'https://api.openai.com/v1');
      expect(back.assistantModel, 'gpt-x');
      final copy = s.copyWith(assistantModel: 'other');
      expect(copy.assistantModel, 'other');
      expect(copy.assistantEnabled, isTrue);
    });

    test('mangled values read as off / default', () {
      final s = AppSettings.fromJson({
        'assistantEnabled': 'yes',
        'assistantProvider': 'mystery',
        'assistantBaseUrl': 5,
        'assistantModel': null,
      });
      expect(s.assistantEnabled, isFalse);
      expect(s.assistantProvider, AssistantProviderKind.anthropic);
      expect(s.assistantBaseUrl, '');
      expect(s.assistantModel, '');
    });

    test('backups carry none of it, and an import keeps this device\'s', () {
      const on = AppSettings(
        assistantEnabled: true,
        assistantProvider: AssistantProviderKind.openAiCompatible,
        assistantBaseUrl: 'https://x.example/v1',
        assistantModel: 'm',
      );
      final defaults = on.withBridgeDefaults();
      expect(defaults.assistantEnabled, isFalse);
      expect(defaults.assistantBaseUrl, '');
      expect(defaults.assistantModel, '');
      expect(defaults.assistantProvider, AssistantProviderKind.anthropic);

      final payload = BackupPayload(
        hosts: const [],
        snippets: const [],
        tunnels: const [],
        bookmarks: const [],
        settings: on,
        includesCredentials: false,
      );
      final text = jsonEncode(payload.toJson());
      expect(text, isNot(contains('assistant')));
      // A file edited by hand to switch it on is forced off on decode.
      final edited = jsonEncode({
        ...payload.toJson(),
        'settings': {
          ...(payload.toJson()['settings'] as Map<String, dynamic>),
          'assistantEnabled': true,
          'assistantModel': 'm',
        },
      });
      final decoded = BackupPayload.decode(
        Uint8List.fromList(utf8.encode(edited)),
      );
      expect(decoded.settings.assistantEnabled, isFalse);
      expect(decoded.settings.assistantModel, '');
      // Restoring settings keeps what this device had.
      final restored = const AppSettings().withBridgeFrom(on);
      expect(restored.assistantEnabled, isTrue);
    });
  });

  group('AssistantService', () {
    late _MemoryStorage storage;
    late AppSettings settings;
    late StreamController<AppSettings> changes;
    late StreamController<bool> lock;
    late List<String> learned;
    late AssistantService service;

    AssistantService build() => AssistantService(
      storage: storage,
      settings: () => settings,
      settingsChanges: changes.stream,
      appLockChanges: lock.stream,
      tools: _IdleHost(),
      learnSecret: learned.add,
    );

    setUp(() {
      storage = _MemoryStorage();
      settings = const AppSettings();
      changes = StreamController<AppSettings>.broadcast(sync: true);
      lock = StreamController<bool>.broadcast(sync: true);
      learned = [];
      service = build();
    });
    tearDown(() async {
      service.dispose();
      await changes.close();
      await lock.close();
    });

    void set(AppSettings s) {
      settings = s;
      changes.add(s);
    }

    test('off and not configured by default', () async {
      await service.load();
      expect(service.isEnabled, isFalse);
      expect(service.isConfigured, isFalse);
      await expectLater(
        service.createConversation(),
        throwsA(
          isA<AssistantFailure>().having(
            (e) => e.message,
            'message',
            contains('switched off'),
          ),
        ),
      );
    });

    test('the key goes to secure storage only, and is taught to the scrubber',
        () async {
      set(const AppSettings(assistantEnabled: true, assistantModel: 'm'));
      await service.load();
      expect(service.configurationProblem, contains('API key'));
      await service.setApiKey('  sk-abcdefghijkl  ');
      expect(
        storage.data[AssistantService.apiKeySecretNameFor(
          AssistantProviderKind.anthropic,
        )],
        'sk-abcdefghijkl',
      );
      expect(service.hasApiKey, isTrue);
      expect(service.isConfigured, isTrue);
      expect(learned, ['sk-abcdefghijkl']);
      // Nothing about it in what settings write.
      expect(jsonEncode(settings.toJson()), isNot(contains('sk-abc')));

      // A new service (a restart) finds it.
      final second = build();
      await second.load();
      expect(second.hasApiKey, isTrue);
      expect(learned.last, 'sk-abcdefghijkl');
      second.dispose();

      await service.clearApiKey();
      expect(storage.data, isEmpty);
      expect(service.isConfigured, isFalse);
    });

    test('a key that cannot be stored throws and is not kept', () async {
      storage.failWrites = true;
      await service.load();
      await expectLater(
        service.setApiKey('sk-abcdefghijkl'),
        throwsA(isA<SecureStorageUnavailableException>()),
      );
      expect(service.hasApiKey, isFalse);
      expect(learned, isEmpty);
    });

    test('what is needed depends on the provider', () async {
      await service.load();
      set(
        const AppSettings(
          assistantEnabled: true,
          assistantProvider: AssistantProviderKind.openAiCompatible,
          assistantModel: 'm',
        ),
      );
      expect(service.configurationProblem, contains('address'));
      set(
        const AppSettings(
          assistantEnabled: true,
          assistantProvider: AssistantProviderKind.openAiCompatible,
          assistantModel: 'm',
          assistantBaseUrl: 'https://api.openai.com/v1',
        ),
      );
      // A switched provider reads its own key first.
      await service.load();
      expect(service.configurationProblem, contains('API key'));
      // A server on this computer may need no key.
      set(
        const AppSettings(
          assistantEnabled: true,
          assistantProvider: AssistantProviderKind.openAiCompatible,
          assistantModel: 'm',
          assistantBaseUrl: 'http://localhost:11434/v1',
        ),
      );
      expect(service.isConfigured, isTrue);
      set(const AppSettings(assistantEnabled: true));
      expect(service.configurationProblem, contains('model'));
    });

    test('switching it off stops running conversations', () async {
      set(const AppSettings(assistantEnabled: true, assistantModel: 'm'));
      await service.setApiKey('sk-abcdefghijkl');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      final hold = Completer<void>();
      server.listen((req) async {
        arrived.complete();
        await hold.future;
        await req.response.close();
      });
      set(
        AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantBaseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      final conv = await service.createConversation();
      final done = conv.send('hi');
      await arrived.future;
      expect(conv.isRunning, isTrue);
      set(settings.copyWith(assistantEnabled: false));
      await done;
      hold.complete();
      await server.close(force: true);
      expect(conv.isRunning, isFalse);
      expect(conv.state.items.last, isA<AssistantNoticeItem>());
      conv.dispose();
    });

    test(
      'switching it off stops a conversation even when the service was built '
      'before the settings loaded',
      () async {
        // main.dart builds the service while the settings store still reads
        // as defaults (off); the saved "on" arrives without a change event.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final arrived = Completer<void>();
        final hold = Completer<void>();
        server.listen((req) async {
          arrived.complete();
          await hold.future;
          await req.response.close();
        });
        settings = AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantBaseUrl: 'http://127.0.0.1:${server.port}',
        );
        await service.setApiKey('sk-abcdefghijkl');
        final conv = await service.createConversation();
        final done = conv.send('hi');
        await arrived.future;
        set(settings.copyWith(assistantEnabled: false));
        await done.timeout(const Duration(seconds: 10));
        hold.complete();
        await server.close(force: true);
        expect(conv.isRunning, isFalse);
        conv.dispose();
      },
    );

    test('each provider has its own key, and only the selected one is used',
        () async {
      set(const AppSettings(assistantEnabled: true, assistantModel: 'm'));
      await service.load();
      await service.setApiKey('sk-ant-SECRET');
      expect(service.hasApiKey, isTrue);

      // Switching to an OpenAI-compatible address: the Anthropic key is not
      // that provider's key.
      final reloaded = service.changes.first;
      set(
        const AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantProvider: AssistantProviderKind.openAiCompatible,
          assistantBaseUrl: 'https://elsewhere.example/v1',
        ),
      );
      await reloaded;
      while (service.configurationProblem?.contains('loaded') ?? false) {
        await service.changes.first;
      }
      expect(service.hasApiKey, isFalse);
      expect(service.configurationProblem, contains('API key'));
      expect(service.buildProvider, throwsA(isA<AssistantFailure>()));

      await service.setApiKey('sk-oai-OTHER');
      expect(
        storage.data[AssistantService.apiKeySecretNameFor(
          AssistantProviderKind.openAiCompatible,
        )],
        'sk-oai-OTHER',
      );
      expect(
        storage.data[AssistantService.apiKeySecretNameFor(
          AssistantProviderKind.anthropic,
        )],
        'sk-ant-SECRET',
      );
      // Removing it removes only this provider's key.
      await service.clearApiKey();
      expect(storage.data.keys, [
        AssistantService.apiKeySecretNameFor(AssistantProviderKind.anthropic),
      ]);
    });

    test('a conversation switched to another provider never sends the old key',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final headers = <String>[];
      server.listen((req) async {
        headers.add(
          '${req.headers.value('authorization')}|'
          '${req.headers.value('x-api-key')}',
        );
        req.response.statusCode = 400;
        req.response.write(jsonEncode({'error': {'message': 'no'}}));
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      set(
        AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantBaseUrl: url,
        ),
      );
      await service.setApiKey('sk-ant-SECRET');
      final conv = await service.createConversation();
      // The same conversation, now pointed at an OpenAI-compatible server on
      // this computer (which may run without a key).
      set(
        AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantProvider: AssistantProviderKind.openAiCompatible,
          assistantBaseUrl: url,
        ),
      );
      await conv.send('hi');
      await server.close(force: true);
      expect(headers, hasLength(1));
      expect(headers.single, isNot(contains('sk-ant')));
      conv.dispose();
    });

    test('a key saved under the old single name moves to the selected provider',
        () async {
      storage.data[AssistantService.legacyApiKeySecretName] = 'sk-old-KEY';
      settings = const AppSettings(
        assistantEnabled: true,
        assistantModel: 'm',
        assistantProvider: AssistantProviderKind.openAiCompatible,
        assistantBaseUrl: 'https://api.openai.com/v1',
      );
      await service.load();
      expect(service.hasApiKey, isTrue);
      expect(learned, ['sk-old-KEY']);
      expect(storage.data, {
        AssistantService.apiKeySecretNameFor(
          AssistantProviderKind.openAiCompatible,
        ): 'sk-old-KEY',
      });

      // Only that provider got it.
      settings = const AppSettings(assistantEnabled: true, assistantModel: 'm');
      await service.load();
      expect(service.hasApiKey, isFalse);
      expect(storage.data, hasLength(1));
    });

    test('the effective address and the host the key goes to', () {
      const anthropic = AppSettings();
      expect(AssistantService.keyDestinationHost(anthropic), 'api.anthropic.com');
      expect(
        AssistantService.keyDestinationHost(
          const AppSettings(
            assistantProvider: AssistantProviderKind.openAiCompatible,
          ),
        ),
        isNull,
      );
      expect(
        AssistantService.keyDestinationHost(
          const AppSettings(
            assistantProvider: AssistantProviderKind.openAiCompatible,
            assistantBaseUrl: ' https://llm.example.org:8443/v1 ',
          ),
        ),
        'llm.example.org',
      );
    });

    test('locking the app stops running conversations', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      final hold = Completer<void>();
      var requests = 0;
      server.listen((req) async {
        requests++;
        if (!arrived.isCompleted) arrived.complete();
        await hold.future;
        await req.response.close();
      });
      set(
        AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantBaseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      await service.setApiKey('sk-abcdefghijkl');
      final conv = await service.createConversation();
      final done = conv.send('hi');
      await arrived.future;
      expect(conv.isRunning, isTrue);
      lock.add(false); // an unlock stops nothing
      expect(conv.isRunning, isTrue);
      lock.add(true);
      await done;
      hold.complete();
      await server.close(force: true);
      expect(conv.isRunning, isFalse);
      expect(conv.state.items.last, isA<AssistantNoticeItem>());
      expect(requests, 1);
      conv.dispose();
    });

    test('an error from the service never shows the key', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = {
          'error': {'message': 'echo ${req.headers.value('x-api-key')}'},
        };
        req.response.statusCode = 400;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
      set(
        AppSettings(
          assistantEnabled: true,
          assistantModel: 'm',
          assistantBaseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      await service.setApiKey('sk-abcdefghijklSECRET');
      final conv = await service.createConversation();
      await conv.send('hi');
      await server.close(force: true);
      final notice = conv.state.items.last as AssistantNoticeItem;
      expect(notice.isError, isTrue);
      expect(notice.text, isNot(contains('SECRET')));
      conv.dispose();
    });
  });

  group('the built-in switch reaches the tool host', () {
    late Directory temp;
    late BridgeToolsRig rig;
    late _MemoryStorage storage;
    late AppSettings settings;
    late AssistantService service;

    setUp(() async {
      temp = await bridgeTempDir('assistant_wiring');
      storage = _MemoryStorage();
      settings = const AppSettings();
      rig = BridgeToolsRig(temp);
      rig.hosts = [bridgeHost('web1', 'web')];
      service = AssistantService(
        storage: storage,
        settings: () => settings,
        tools: rig.tools,
      );
    });
    tearDown(() async {
      service.dispose();
      await deleteTempDir(temp);
    });

    test('the tool host refuses the built-in client while it is off', () async {
      // Wired exactly as main.dart wires it.
      Future<BridgeToolResult> call() async {
        rig.builtinOn = service.isEnabled;
        return rig.tools.call(BridgeClient.builtin, 'list_hosts', const {});
      }

      var r = await call();
      expect(r.text, BridgeRefusals.bridgeOff.message);
      settings = const AppSettings(assistantEnabled: true);
      r = await call();
      expect(r.isError, isFalse);
      expect(rig.entries.last.client, 'Built-in assistant');
    });
  });
}
