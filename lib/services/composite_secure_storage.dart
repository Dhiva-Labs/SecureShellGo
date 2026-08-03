import 'dart:convert';
import 'dart:io';

import 'app_data_paths.dart';
import 'secret_vault.dart';
import 'secure_storage_backend.dart';

/// Which store a secure-storage operation should go to right now.
enum SecureStorageChoice {
  /// The OS keyring, and it answered.
  keyring,

  /// The passphrase vault, because this install has one.
  vault,

  /// The OS keyring has worked here before and is not answering now, and no
  /// vault exists. The user has a keyring; it is locked. Nothing is stored
  /// and nothing is moved.
  keyringLocked,

  /// No keyring has ever worked here and there is no vault yet. This is the
  /// only state in which the app offers to make one.
  vaultSetupRequired,
}

/// Picks between the OS keyring and the passphrase vault, per operation.
///
/// ## The selection rule
///
/// In order, and the order is the whole point:
///
///  1. **A vault exists → the vault.** Once secrets are in a vault, that is
///     where they are. Switching back because a keyring turned up would make
///     every credential the user saved appear to vanish, since nothing has
///     copied them across. Migration is deliberately out of scope here — see
///     the note at the end.
///  2. **The keyring answers → the keyring.** The best protection available
///     wins whenever it is actually available, and this is recorded (see
///     [SecureStorageState]) as proof that this install *has* a keyring.
///  3. **The keyring has answered before but not now → [keyringLocked].**
///     This is the case the whole design exists to *not* mishandle. A user
///     whose keyring worked yesterday and is locked today has a keyring; the
///     fix is to unlock it. Offering to move their secrets into a passphrase
///     vault would be trading a keystore-backed store for a file, on the
///     strength of a transient failure, and the user would very likely take
///     the offer because it is the button in front of them. So this state
///     refuses the write and says "unlock it" — the app cannot silently
///     downgrade, because the only path into the vault runs through
///     [vaultSetupRequired], which this install can never reach again once
///     the keyring has been seen working even once.
///  4. **Neither → [vaultSetupRequired].** No keyring has ever worked here:
///     a snap with `password-manager-service` unconnected, a desktop with no
///     Secret Service daemon, a headless box. This is the dead end the vault
///     is for, and the only state where the UI offers to create one.
///
/// The "has ever worked" bit is persisted, not remembered for the session:
/// a keyring that works only until the app restarts would otherwise be
/// enough to reach step 4 on the next launch.
///
/// ## Not implemented on purpose
///
/// A user who gains a working keyring after building a vault keeps using the
/// vault (step 1). Moving secrets across is a real migration — read every
/// entry out of one store, write it into the other, and decide what to do
/// when half of it fails — and doing half of it here would be worse than
/// not doing it. Left as future work, with the vault as the honest status
/// quo until then.
class CompositeSecureStorageBackend implements SecureStorageBackend {
  CompositeSecureStorageBackend({
    required SecureStorageBackend keyring,
    required SecretVault vault,
    required Future<bool> Function() keyringAvailable,
    SecureStorageState? state,
    Future<String?> Function()? requestUnlockPassphrase,
    Map<String, String>? environment,
  })  :
        // ignore: prefer_initializing_formals
        _keyring = keyring,
        // ignore: prefer_initializing_formals
        _vault = vault,
        // ignore: prefer_initializing_formals
        _keyringAvailable = keyringAvailable,
        _state = state ?? SecureStorageState(),
        // ignore: prefer_initializing_formals
        _requestUnlockPassphrase = requestUnlockPassphrase,
        // ignore: prefer_initializing_formals
        _environment = environment;

  final SecureStorageBackend _keyring;
  final SecretVault _vault;
  final Future<bool> Function() _keyringAvailable;
  final SecureStorageState _state;

  /// How the vault asks for its passphrase when something needs a secret and
  /// the vault is sealed. Supplied by the app layer (see `main.dart`), the
  /// same shape as `SshService`'s `verifyHostKey` prompt: the service knows
  /// *when* to ask, the UI knows *how*. Null in tests and on any build with
  /// no way to prompt, in which case a sealed vault simply stays sealed.
  final Future<String?> Function()? _requestUnlockPassphrase;

  /// Tests only — see [isRunningAsSnap].
  final Map<String, String>? _environment;

  /// The pure decision, kept free of I/O so the rule above can be tested for
  /// what it is rather than through a filesystem. [resolve] is the thin
  /// wrapper that supplies the real three facts.
  static SecureStorageChoice choose({
    required bool vaultExists,
    required bool keyringAvailable,
    required bool keyringEverAvailable,
  }) {
    if (vaultExists) return SecureStorageChoice.vault;
    if (keyringAvailable) return SecureStorageChoice.keyring;
    if (keyringEverAvailable) return SecureStorageChoice.keyringLocked;
    return SecureStorageChoice.vaultSetupRequired;
  }

  /// The current choice, and the one place the "this install has a keyring"
  /// fact gets recorded.
  Future<SecureStorageChoice> resolve() async {
    if (await _vault.exists()) return SecureStorageChoice.vault;
    final available = await _keyringAvailable();
    if (available) {
      await _state.recordKeyringAvailable();
      return SecureStorageChoice.keyring;
    }
    return choose(
      vaultExists: false,
      keyringAvailable: false,
      keyringEverAvailable: await _state.keyringEverAvailable(),
    );
  }

  @override
  Future<void> write(String key, String value) async {
    switch (await resolve()) {
      case SecureStorageChoice.keyring:
        try {
          await _keyring.write(key, value);
        } on SecureStorageUnavailableException catch (e) {
          // The keyring answered the availability probe and then locked
          // between that and this write — the race the probe's own doc warns
          // about. It is still a keyring this install has, so the remedy is
          // the same "unlock it", never a vault. Anything that is not a lock
          // (a real libsecret error) is passed through as it came.
          if (e.code != 'KeyringLocked') rethrow;
          throw SecureStorageUnavailableException(
            keyringLockedMessage,
            code: e.code,
            remedy: SecureStorageRemedy.unlockKeyring,
          );
        }
      case SecureStorageChoice.vault:
        await _requireUnlockedVault();
        await _vault.write(key, value);
      case SecureStorageChoice.keyringLocked:
        throw SecureStorageUnavailableException(
          keyringLockedMessage,
          code: 'KeyringLocked',
          remedy: SecureStorageRemedy.unlockKeyring,
        );
      case SecureStorageChoice.vaultSetupRequired:
        throw SecureStorageUnavailableException(
          keyringUnavailableMessage(environment: _environment),
          code: 'KeyringLocked',
          remedy: SecureStorageRemedy.offerVault,
        );
    }
  }

  /// Fails closed exactly like [FlutterSecureStorageBackend.read] does: a
  /// secret that cannot be reached reads as one that was never saved, and the
  /// caller ends up asking the user rather than connecting with a guess.
  ///
  /// A sealed vault is the one case worth an extra step first, because "there
  /// is nothing saved" would be a lie about a file we can see: if the app
  /// gave us a way to ask, ask. Declining the prompt still fails closed.
  @override
  Future<String?> read(String key) async {
    switch (await resolve()) {
      case SecureStorageChoice.keyring:
        return _keyring.read(key);
      case SecureStorageChoice.vault:
        if (!await _tryUnlockVault()) return null;
        try {
          return await _vault.read(key);
        } on SecretVaultException {
          return null;
        }
      case SecureStorageChoice.keyringLocked:
      case SecureStorageChoice.vaultSetupRequired:
        return null;
    }
  }

  @override
  Future<void> delete(String key) async {
    switch (await resolve()) {
      case SecureStorageChoice.keyring:
        await _keyring.delete(key);
      case SecureStorageChoice.vault:
        if (!await _tryUnlockVault()) return;
        try {
          await _vault.delete(key);
        } on SecretVaultException {
          // Best-effort, like the keyring backend: nothing to clean up if the
          // store cannot be reached.
        }
      case SecureStorageChoice.keyringLocked:
      case SecureStorageChoice.vaultSetupRequired:
        // Nothing was ever stored through a store that does not exist.
        break;
    }
  }

  /// Whether a [write] would currently land somewhere. Not authoritative —
  /// the keyring can lock, and the vault can be sealed, between this call and
  /// the next write.
  Future<bool> isAvailable() async {
    final choice = await resolve();
    return choice == SecureStorageChoice.keyring ||
        choice == SecureStorageChoice.vault;
  }

  /// Creates the passphrase vault. Only meaningful in
  /// [SecureStorageChoice.vaultSetupRequired]; refuses otherwise, so a screen
  /// cannot turn a locked keyring into a vault by asking twice.
  Future<void> createVault(String passphrase) async {
    final choice = await resolve();
    if (choice != SecureStorageChoice.vaultSetupRequired) {
      throw const SecretVaultStateException(
        'This device already has somewhere to keep credentials.',
      );
    }
    await _vault.create(passphrase);
  }

  /// Opens an existing vault for this session. Throws
  /// [SecretVaultAuthException] on a wrong passphrase, having changed
  /// nothing.
  Future<void> unlockVault(String passphrase) => _vault.unlock(passphrase);

  bool get isVaultUnlocked => _vault.isUnlocked;

  Future<bool> vaultExists() => _vault.exists();

  /// The message for a keyring this install has seen working. Never mentions
  /// the vault: offering one here is precisely the downgrade the rule above
  /// exists to prevent.
  ///
  /// It says "could not be reached or unlocked" rather than "is locked"
  /// because the platform cannot tell us which — see
  /// [keyringUnavailableMessage]. What this install *can* say for certain is
  /// the useful part: the keyring worked here before, so it exists and the
  /// fix is to get it answering again.
  static const String keyringLockedMessage =
      'Your system keyring could not be reached or unlocked, so this '
      'credential cannot be protected right now. It has worked on this '
      'device before, so nothing needs installing — unlock it (log in to '
      'your desktop keyring, or start GNOME Keyring / KWallet) and save '
      'again.';

  Future<void> _requireUnlockedVault() async {
    if (await _tryUnlockVault()) return;
    throw const SecureStorageUnavailableException(
      'The credential vault is locked. Enter its passphrase to save this '
      'credential.',
      remedy: SecureStorageRemedy.unlockVault,
    );
  }

  /// One unlock at a time, shared by every caller that arrives while it is
  /// running. The host list asks for several hosts' credentials at once on a
  /// cold start, and without this each of them would stack up its own
  /// passphrase dialog.
  Future<bool>? _unlocking;

  /// True if the vault is open, opening it via the app's prompt if there is
  /// one. A wrong passphrase is not retried here — the caller surfaces it and
  /// the user can try again — because a silent retry loop is how a prompt
  /// becomes impossible to cancel.
  Future<bool> _tryUnlockVault() {
    if (_vault.isUnlocked) return Future<bool>.value(true);
    return _unlocking ??= _unlockVault().whenComplete(() {
      _unlocking = null;
    });
  }

  Future<bool> _unlockVault() async {
    final prompt = _requestUnlockPassphrase;
    if (prompt == null) return false;
    final passphrase = await prompt();
    if (passphrase == null) return false;
    try {
      await _vault.unlock(passphrase);
      return true;
    } on SecretVaultException {
      return false;
    }
  }
}

/// The one fact the selection rule needs to remember across launches: has the
/// OS keyring ever answered on this install.
///
/// A plain JSON file next to `hosts.json` in the app's private data
/// directory. It holds no secret — only a boolean about the *platform* — so
/// it deliberately does not go through secure storage, which would be
/// circular anyway.
class SecureStorageState {
  /// [file] overrides the on-disk location; tests use it so they do not need
  /// the path_provider plugin.
  // ignore: prefer_initializing_formals
  SecureStorageState({File? file}) : _file = file;

  static const String fileName = 'secure_storage_state.json';

  File? _file;
  bool? _cached;

  Future<bool> keyringEverAvailable() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return _cached = false;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['keyringEverAvailable'] == true) {
        return _cached = true;
      }
    } catch (_) {
      // An unreadable marker means "we do not know". Answering false here is
      // the cautious direction only in the sense of not blocking a user who
      // genuinely has no keyring; a user who does have one reaches step 2 of
      // the rule and re-records it on the spot.
    }
    return _cached = false;
  }

  Future<void> recordKeyringAvailable() async {
    if (_cached == true) return;
    _cached = true;
    try {
      final file = await _resolveFile();
      await file.writeAsString(
        jsonEncode(<String, dynamic>{'keyringEverAvailable': true}),
        flush: true,
      );
    } catch (_) {
      // Losing this only costs a re-record on the next launch, and the
      // keyring is working right now either way — not worth failing a save
      // the user asked for.
    }
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }
}
