import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/app_settings.dart';
import 'screens/host_list_screen.dart';
import 'services/app_lock.dart';
import 'services/app_lock_controller.dart';
import 'services/backup_service.dart';
import 'services/bookmark_store.dart';
import 'services/credential_store.dart';
import 'services/host_store.dart';
import 'services/known_hosts_integrity.dart';
import 'services/known_hosts_service.dart';
import 'services/session_manager.dart';
import 'services/settings_store.dart';
import 'services/snippet_store.dart';
import 'services/ssh_service.dart';
import 'services/terminal_workspace.dart';
import 'services/tunnel_runtime.dart';
import 'services/tunnel_store.dart';
import 'theme.dart';
import 'widgets/app_lock_gate.dart';

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
  // The jump-host resolver turns a saved host's `jumpHostId` into the hop's
  // own record and its own credentials, so every bastion in a chain is
  // authenticated and host-key checked exactly like a target is. The stores
  // are `late final` too, so naming them here before their own declarations
  // is fine — nothing is built until the first connect touches it.
  late final SshService _sshService = SshService(
    knownHosts: _knownHosts,
    jumpHosts: JumpHostResolver(
      lookupHost: _hostStore.get,
      loadCredentials: _credentialStore.load,
    ),
  );
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

  // The saved port forwards, and whatever is currently listening for them.
  //
  // Built here for the same reason the sessions are, and more so: a tunnel
  // exists precisely so that something else — a browser, a database client,
  // a deploy script — can use it while the user is doing something entirely
  // different in this app. Tying one to the screen that started it would
  // mean closing that screen tore down the forward the user had just set up.
  //
  // A tunnel rides on a live session's transport when there is one (no
  // second authentication, no second host-key prompt) and opens its own
  // connection otherwise, through the ordinary `SshService.connect` — so
  // jump chains, known-hosts checks and TOFU prompts are the same ones every
  // other connection in the app goes through, not a second copy of them.
  late final TunnelStore _tunnelStore = TunnelStore();
  late final TunnelRuntime _tunnels = TunnelRuntime(
    profiles: _tunnelStore,
    support: TunnelSupport(
      lookupHost: _hostStore.get,
      loadCredentials: _credentialStore.load,
      connect: ({
        required host,
        required credentials,
        required verifyHostKey,
      }) async =>
          SshTunnelCarrier.dedicated(
        await _sshService.connect(
          host: host,
          credentials: credentials,
          verifyHostKey: verifyHostKey,
        ),
      ),
      findSessionCarrier: _sessionCarrierFor,
      // How a tunnel finds out that the session carrying it has reconnected:
      // `SessionController.adoptTransport` notifies on its own change stream,
      // which the manager folds into this one.
      sessionChanges: _sessions.changes,
    ),
  );

  /// A live session's transport for [hostId], dressed as something a tunnel
  /// can forward over, or null when nothing is open on that host.
  ///
  /// Borrowed, never owned: stopping a tunnel must not hang up on the shell
  /// the user is typing in. See [TunnelCarrier.release].
  TunnelCarrier? _sessionCarrierFor(String hostId) {
    for (final session in _sessions.sessions) {
      if (session.host.id != hostId || session.isClosed) continue;
      final transport = session.controller.connection;
      if (transport is SshConnection) {
        return SshTunnelCarrier.borrowed(transport.client);
      }
    }
    return null;
  }

  // The desktop split layout. Built here for the same reason the sessions are:
  // going back to the host list to open another server tears the sessions
  // screen down, and coming back must find the panes, the dividers and the
  // bindings exactly where they were left.
  //
  // The resolver is how broadcast input reaches the shells behind the visible
  // panes (see `broadcast_input.dart`); the workspace itself holds only
  // session ids. Mobile builds this and never reads it.
  // The optional app lock. Built here rather than inside a route because the
  // gate has to sit above the entire navigator — see `app_lock_gate.dart` for
  // why it is an overlay and not a pushed route — and because the idle
  // timeout has to keep running while any screen at all is in front.
  //
  // It is given no store, no session manager and no tunnel runtime, and that
  // is deliberate: locking the screen must not be able to disconnect anything
  // or delete anything. See `app_lock_controller.dart`.
  late final AppLockController _appLock = AppLockController(
    authenticator: createDefaultAppLockAuthenticator(),
  );

  /// Feeds settings changes to the lock, so toggling it in Settings takes
  /// effect without the settings screen having to know the controller exists.
  StreamSubscription<AppSettings>? _settingsWatch;

  // The encrypted backup/restore feature. Every store it touches is one that
  // already lives here, so this adds no new persistence — only a way to get
  // what is already persisted in and out as one file.
  //
  // `BookmarkStore.instance` rather than a fresh one: the file browser
  // reaches its bookmarks through that shared instance, and a second in-memory
  // copy here would let the two drift apart within one process.
  late final SnippetStore _snippetStore = SnippetStore();
  late final BackupService _backupService = BackupService(
    hostStore: _hostStore,
    snippetStore: _snippetStore,
    tunnelStore: _tunnelStore,
    bookmarkStore: BookmarkStore.instance,
    settingsStore: _settingsStore,
    credentialStore: _credentialStore,
  );

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
    // The lock has to be decided from the *loaded* settings, not the defaults
    // the store reads as before its first disk read completes — otherwise a
    // user with the lock on would get one unguarded frame of their host list
    // on every cold start.
    unawaited(
      _settingsStore.ensureLoaded().then((_) {
        if (!mounted) return;
        unawaited(_appLock.start(_settingsStore.current));
      }),
    );
    _settingsWatch = _settingsStore.changes.listen(_appLock.applySettings);
  }

  @override
  void dispose() {
    // Closes every live connection and releases the foreground service. The
    // app going away is the one thing that ends a session the user did not
    // close themselves.
    unawaited(_sessions.dispose());
    // Stops every listener and closes the connections the tunnels opened for
    // themselves; the ones borrowed from sessions go with the sessions above.
    unawaited(_tunnels.dispose());
    unawaited(_workspace.dispose());
    unawaited(_settingsWatch?.cancel());
    _appLock.dispose();
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
      // `builder`, so the gate is inserted *above* the Navigator rather than
      // inside it. Nothing the app pushes can end up on top of the lock, and
      // there is no lock route for a back gesture to pop.
      builder: (context, child) => AppLockGate(
        controller: _appLock,
        child: child ?? const SizedBox.shrink(),
      ),
      home: HostListScreen(
        hostStore: _hostStore,
        credentialStore: _credentialStore,
        knownHosts: _knownHosts,
        sshService: _sshService,
        settingsStore: _settingsStore,
        sessions: _sessions,
        workspace: _workspace,
        tunnels: _tunnels,
        snippetStore: _snippetStore,
        appLock: _appLock,
        backupService: _backupService,
      ),
    );
  }
}
