import 'dart:async';

import '../../models/app_settings.dart';
import '../bridge/bridge_approvals.dart';
import '../bridge/bridge_tool_types.dart';
import '../secure_storage_backend.dart';
import 'anthropic_provider.dart';
import 'assistant_conversation.dart';
import 'assistant_http.dart';
import 'assistant_types.dart';
import 'openai_provider.dart';

/// The built-in assistant as the rest of the app sees it: reads the
/// settings and the API key, builds the right provider, and creates
/// conversations. Built once in `main.dart`.
///
/// Each provider kind has its own API key, in secure storage under
/// [apiKeySecretNameFor] and in memory while the app runs, and only the key
/// of the provider selected right now is read, taught, or sent: an Anthropic
/// key must never go out as a Bearer header to an OpenAI-compatible address
/// typed in later. The key is It is not in settings.json, is not part of
/// a backup, and is taught to [learnSecret] so the diagnostics log and the
/// activity log scrub it wherever it might turn up.
class AssistantService {
  AssistantService({
    required this._storage,
    required this._settings,
    required this._tools,
    Stream<AppSettings>? settingsChanges,
    Stream<bool>? appLockChanges,
    this._approvals,
    this._learnSecret,
    this._httpClientFactory,
    this._limits = const AssistantHttpLimits(),
  }) {
    _settingsWatch = settingsChanges?.listen(_onSettings);
    // A locked app refuses every tool call, but a running turn would still
    // keep asking the AI service; stop it outright, as the bridge ends its
    // own sessions on a lock. [appLockChanges] is true on each lock.
    _lockWatch = appLockChanges?.listen((locked) {
      if (locked) stopAll();
    });
  }

  /// The secure-storage entry for [kind]'s API key. Distinct from every
  /// `credentials:<hostId>` entry, which are the only ones a backup reads.
  static String apiKeySecretNameFor(AssistantProviderKind kind) =>
      'assistant:apiKey:${kind.name}';

  /// Where 1.8.0 previews kept the one key used for every provider. Read
  /// once by [load], moved to the provider selected at that moment, then
  /// deleted.
  static const String legacyApiKeySecretName = 'assistant:apiKey';

  /// The address requests (and so the key) go to for [s]: the typed one, or
  /// Anthropic's own when that provider's field is left empty. Null when
  /// there is none yet (an OpenAI-compatible service with no address).
  static String? effectiveBaseUrl(AppSettings s) {
    final typed = s.assistantBaseUrl.trim();
    if (typed.isNotEmpty) return typed;
    return s.assistantProvider == AssistantProviderKind.anthropic
        ? AnthropicProvider.defaultBaseUrl
        : null;
  }

  /// The host part of [effectiveBaseUrl], for the line in Settings that says
  /// where the key will be sent. Null when there is no usable address.
  static String? keyDestinationHost(AppSettings s) {
    final url = effectiveBaseUrl(s);
    if (url == null) return null;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? null : host;
  }

  final SecureStorageBackend _storage;
  final AppSettings Function() _settings;
  final BridgeToolHost _tools;
  final Stream<List<BridgeApprovalRequest>>? _approvals;
  final void Function(String secret)? _learnSecret;
  final AssistantHttpClientFactory? _httpClientFactory;
  final AssistantHttpLimits _limits;

  StreamSubscription<AppSettings>? _settingsWatch;
  StreamSubscription<bool>? _lockWatch;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<AssistantConversation> _live = [];
  String? _apiKey;

  /// Which provider [_apiKey] and [_keySealed] belong to; null before the
  /// first [load]. When the selected provider differs, the key in memory is
  /// treated as not loaded, so it is never used for the other provider.
  AssistantProviderKind? _keyKind;
  bool _keySealed = false;

  bool get _keyLoaded => _keyKind == _settings().assistantProvider;

  /// The switch in Settings. Off by default.
  bool get isEnabled => _settings().assistantEnabled;

  /// Fires when the key or the settings it depends on changed.
  Stream<void> get changes => _changes.stream;

  /// Whether a conversation could be started now: a key (a local server may
  /// need none, see below), a model and, for an OpenAI-compatible service, an
  /// address. Call [load] first; before it, a saved key is not yet known.
  bool get isConfigured => configurationProblem == null;

  /// Why [isConfigured] is false, in plain words; null when it is true.
  String? get configurationProblem {
    final s = _settings();
    if (s.assistantModel.trim().isEmpty) {
      return 'Enter the model name in the assistant settings.';
    }
    final needsAddress = s.assistantProvider ==
        AssistantProviderKind.openAiCompatible;
    if (needsAddress && s.assistantBaseUrl.trim().isEmpty) {
      return 'Enter the address of the AI service in the assistant settings.';
    }
    if (_mayRunKeyless(s)) return null;
    // Checked after the address: the key in memory may belong to the
    // provider selected before, and is then not this provider's key.
    if (!_keyLoaded) return 'The assistant settings have not loaded yet.';
    if (_keySealed) {
      return 'The saved API key is in a locked store. Unlock it by opening '
          'a saved server once, then try again.';
    }
    if (!hasApiKey) {
      return 'Add an API key in the assistant settings.';
    }
    return null;
  }

  /// A server on this computer may need no key.
  bool _mayRunKeyless(AppSettings s) {
    if (s.assistantProvider != AssistantProviderKind.openAiCompatible) {
      return false;
    }
    final uri = Uri.tryParse(s.assistantBaseUrl.trim());
    final host = uri?.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  /// Whether the selected provider has a key saved.
  bool get hasApiKey => _keyLoaded && (_apiKey ?? '').isNotEmpty;

  /// Reads the selected provider's saved key. Never asks the user for
  /// anything: a locked store is reported by [configurationProblem], not
  /// prompted.
  Future<void> load() async {
    final kind = _settings().assistantProvider;
    final name = apiKeySecretNameFor(kind);
    String? key;
    var sealed = false;
    try {
      key = await readSecureStorageQuietly(_storage, name);
      key ??= await _migrateLegacyKey(name);
    } on SecureStorageSealed {
      sealed = true;
    } catch (_) {
      key = null;
    }
    _apiKey = key;
    _keySealed = sealed;
    _keyKind = kind;
    if (key != null) _learnSecret?.call(key);
    _notify();
  }

  /// Moves a key saved under [legacyApiKeySecretName] to [name] (the
  /// provider selected now) and deletes the old entry. Returns the moved key,
  /// or null when there was none. A failed write keeps the old entry, so the
  /// next start tries again rather than losing the key.
  Future<String?> _migrateLegacyKey(String name) async {
    final old = await readSecureStorageQuietly(_storage, legacyApiKeySecretName);
    if (old == null) return null;
    final trimmed = old.trim();
    if (trimmed.isNotEmpty) await _storage.write(name, trimmed);
    await _storage.delete(legacyApiKeySecretName);
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Saves [key] (trimmed) to secure storage. Throws
  /// [SecureStorageUnavailableException] with a message for the user when
  /// the platform cannot protect it; nothing is kept in that case.
  Future<void> setApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await clearApiKey();
      return;
    }
    final kind = _settings().assistantProvider;
    await _storage.write(apiKeySecretNameFor(kind), trimmed);
    _apiKey = trimmed;
    _keySealed = false;
    _keyKind = kind;
    _learnSecret?.call(trimmed);
    _notify();
  }

  Future<void> clearApiKey() async {
    final kind = _settings().assistantProvider;
    await _storage.delete(apiKeySecretNameFor(kind));
    _apiKey = null;
    _keySealed = false;
    _keyKind = kind;
    _notify();
  }

  /// A new conversation. Throws [AssistantFailure] (kind config) when the
  /// assistant is off or not set up, with text for the user. The provider is
  /// built again for each request, so a model or key changed in Settings
  /// applies to the next message.
  Future<AssistantConversation> createConversation() async {
    if (!isEnabled) {
      throw const AssistantFailure(
        AssistantFailureKind.config,
        'The built-in assistant is switched off in Settings.',
      );
    }
    if (!_keyLoaded) await load();
    final problem = configurationProblem;
    if (problem != null) {
      throw AssistantFailure(AssistantFailureKind.config, problem);
    }
    final conversation = AssistantConversation(
      provider: () async {
        // The provider may have been switched since the last message; read
        // that provider's own key before building, never reuse the old one.
        if (!_keyLoaded) await load();
        return buildProvider();
      },
      tools: _tools,
      approvals: _approvals,
    );
    _live.add(conversation);
    // Dropped from the live list once its owner disposes it.
    unawaited(
      conversation.changes.drain<void>().whenComplete(
        () => _live.remove(conversation),
      ),
    );
    return conversation;
  }

  /// The provider for the current settings and key. Public for tests.
  AssistantProvider buildProvider() {
    final s = _settings();
    if (!isEnabled) {
      throw const AssistantFailure(
        AssistantFailureKind.config,
        'The built-in assistant is switched off in Settings.',
      );
    }
    final problem = configurationProblem;
    if (problem != null) {
      throw AssistantFailure(AssistantFailureKind.config, problem);
    }
    // Only ever the selected provider's own key; a server on this computer
    // reached before that key was read gets none.
    final key = _keyLoaded ? (_apiKey ?? '') : '';
    final model = s.assistantModel.trim();
    return switch (s.assistantProvider) {
      AssistantProviderKind.anthropic => AnthropicProvider(
        apiKey: key,
        model: model,
        baseUrl: s.assistantBaseUrl,
        httpClientFactory: _httpClientFactory,
        limits: _limits,
      ),
      AssistantProviderKind.openAiCompatible => OpenAiCompatibleProvider(
        apiKey: key,
        model: model,
        baseUrl: s.assistantBaseUrl,
        httpClientFactory: _httpClientFactory,
        limits: _limits,
      ),
    };
  }

  void _onSettings(AppSettings s) {
    final enabled = s.assistantEnabled;
    // On every "off", not only an on-to-off seen here: the service may have
    // been built while the settings still read as defaults, and a saved "on"
    // arrives without an event. Stopping an idle conversation does nothing.
    if (!enabled) stopAll();
    // A switched provider uses its own key, which has to be read first.
    if (_keyKind != null && _keyKind != s.assistantProvider) {
      unawaited(load());
    }
    _notify();
  }

  /// Stops every running conversation (each says it was stopped). Used when
  /// the assistant is switched off and when the app locks.
  void stopAll() {
    for (final c in List.of(_live)) {
      c.stop();
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    for (final c in List.of(_live)) {
      c.dispose();
    }
    _live.clear();
    unawaited(_settingsWatch?.cancel());
    unawaited(_lockWatch?.cancel());
    unawaited(_changes.close());
  }
}
