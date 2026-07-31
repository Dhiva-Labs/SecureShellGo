import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/host_list_screen.dart';
import 'services/credential_store.dart';
import 'services/host_store.dart';
import 'services/known_hosts_integrity.dart';
import 'services/known_hosts_service.dart';
import 'services/session_manager.dart';
import 'services/settings_store.dart';
import 'services/ssh_service.dart';
import 'services/terminal_workspace.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const SecureShellGoApp());
}

class SecureShellGoApp extends StatefulWidget {
  const SecureShellGoApp({super.key});

  @override
  State<SecureShellGoApp> createState() => _SecureShellGoAppState();
}

class _SecureShellGoAppState extends State<SecureShellGoApp> {
  // Composition root. Services take their dependencies through constructors
  // and hold no globals, so there is no service locator here — see
  // ARCHITECTURE.md.
  late final SecureStorageBackend _secureStorage = FlutterSecureStorageBackend();

  // known_hosts.json is sealed with an HMAC whose key lives in the Keystore.
  // Fingerprints are public, so this is not about secrecy — it is about a
  // rewritten file being unable to silence the MITM warning.
  late final KnownHostsService _knownHosts = KnownHostsService(
    integrityKey: KnownHostsIntegrityKey(_secureStorage),
  );
  late final SshService _sshService = SshService(knownHosts: _knownHosts);
  late final HostStore _hostStore = HostStore();
  late final CredentialStore _credentialStore =
      CredentialStore(backend: _secureStorage);
  late final SettingsStore _settingsStore = SettingsStore();

  // The open sessions. Built here, not by a route, because a session has to
  // outlive the screen showing it: going back to this host list is how a
  // *second* session gets started, and it must not cost the first one. See
  // `session_manager.dart`.
  //
  // The direct server-to-server path needs the *destination* host's saved
  // credential at the moment a transfer runs; the manager is the one place
  // above every session's controller with the credential store in scope.
  // The lookup is scoped to the one host id at the point of use — no
  // credential is ever exposed to the source server beyond the single
  // signing session an [SSHAgentHandler] hands out on request.
  //
  // The same two dependencies also let a session rebuild its own transport
  // after the network drops underneath it. Nothing new is cached: the
  // credential is fetched from the existing store at the moment an attempt
  // runs, and the connect goes through the same `SshService` — and therefore
  // the same known-hosts check — that a hand-made connection does.
  late final SessionManager _sessions = SessionManager(
    resolveDestinationCredentials: _credentialStore.load,
    reconnect: ReconnectSupport(
      loadCredentials: _credentialStore.load,
      connect: ({
        required host,
        required credentials,
        required verifyHostKey,
      }) =>
          _sshService.connect(
        host: host,
        credentials: credentials,
        verifyHostKey: verifyHostKey,
      ),
    ),
  );

  // The desktop split layout. Built here for the same reason the sessions are:
  // going back to the host list to open another server tears the sessions
  // screen down, and coming back must find the panes, the dividers and the
  // bindings exactly where they were left.
  //
  // The resolver is how broadcast input reaches the shells behind the visible
  // panes (see `broadcast_input.dart`); the workspace itself holds only
  // session ids. Mobile builds this and never reads it.
  late final TerminalWorkspace _workspace = TerminalWorkspace(
    resolveSession: (id) {
      final session = _sessions.byId(id);
      if (session == null) return null;
      return LiveWorkspaceSession(session.id, session.controller);
    },
  );

  @override
  void initState() {
    super.initState();
    // Warm the known-hosts and host stores so the first connect does not
    // stall on I/O in the middle of the handshake, and the host list does
    // not show a spinner on a cold start.
    _knownHosts.ensureLoaded();
    _hostStore.ensureLoaded();
    _settingsStore.ensureLoaded();
  }

  @override
  void dispose() {
    // Closes every live connection and releases the foreground service. The
    // app going away is the one thing that ends a session the user did not
    // close themselves.
    unawaited(_sessions.dispose());
    unawaited(_workspace.dispose());
    _settingsStore.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SecureShell Go',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      home: HostListScreen(
        hostStore: _hostStore,
        credentialStore: _credentialStore,
        knownHosts: _knownHosts,
        sshService: _sshService,
        settingsStore: _settingsStore,
        sessions: _sessions,
        workspace: _workspace,
      ),
    );
  }
}
