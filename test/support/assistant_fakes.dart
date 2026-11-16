import 'dart:async';

import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/assistant/assistant_conversation.dart';
import 'package:secure_shell_go/services/assistant/assistant_service.dart';
import 'package:secure_shell_go/services/host_store.dart';

/// A conversation a test drives by hand: it records what the screen sends
/// and shows whatever items the test sets.
class FakeConversation implements AssistantConversation {
  final StreamController<AssistantConversationState> _changes =
      StreamController<AssistantConversationState>.broadcast(sync: true);
  AssistantConversationState _state = const AssistantConversationState(
    [],
    isRunning: false,
  );
  final List<String> sent = [];
  int stops = 0;
  bool disposed = false;

  @override
  AssistantConversationState get state => _state;

  @override
  Stream<AssistantConversationState> get changes => _changes.stream;

  @override
  bool get isRunning => _state.isRunning;

  /// What the engine does: emits the new transcript.
  void show(List<AssistantTranscriptItem> items, {bool running = false}) {
    _state = AssistantConversationState(items, isRunning: running);
    _changes.add(_state);
  }

  @override
  Future<void> send(String text) async {
    sent.add(text);
    show([
      ..._state.items,
      AssistantUserItem(_state.items.length + 1, text),
    ], running: true);
  }

  @override
  void stop() => stops++;

  @override
  void dispose() {
    disposed = true;
    unawaited(_changes.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The service as the screens see it, with every answer set by the test.
class FakeAssistantService implements AssistantService {
  FakeAssistantService({this.enabled = true, this.problem, bool keySaved = false}) {
    this.keySaved = keySaved;
  }

  bool enabled;
  String? problem;

  /// The provider selected now; the real service keeps one key per provider
  /// and answers for the selected one only. A test host sets this when the
  /// settings change.
  AssistantProviderKind provider = AssistantProviderKind.anthropic;
  final Map<AssistantProviderKind, bool> _saved = {};

  /// Whether the selected provider has a key.
  bool get keySaved => _saved[provider] ?? false;
  set keySaved(bool value) => _saved[provider] = value;

  /// Which provider each saved key was saved for, in order.
  final List<AssistantProviderKind> savedFor = [];

  /// Thrown by [setApiKey] and [clearApiKey] when set.
  Object? keyError;
  final List<String> savedKeys = [];
  int clears = 0;
  final List<FakeConversation> created = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void changed() => _changes.add(null);

  @override
  bool get isEnabled => enabled;

  @override
  bool get isConfigured => problem == null;

  @override
  String? get configurationProblem => problem;

  @override
  bool get hasApiKey => keySaved;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> setApiKey(String key) async {
    if (keyError != null) throw keyError!;
    savedKeys.add(key);
    savedFor.add(provider);
    keySaved = true;
    changed();
  }

  @override
  Future<void> clearApiKey() async {
    if (keyError != null) throw keyError!;
    clears++;
    keySaved = false;
    changed();
  }

  @override
  Future<AssistantConversation> createConversation() async {
    final c = FakeConversation();
    created.add(c);
    return c;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A host list a test sets directly.
class FakeHostList implements HostStore {
  FakeHostList(this.hosts);
  List<Host> hosts;

  @override
  Future<List<Host>> all() async => hosts;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
