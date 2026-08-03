import 'dart:convert';
import 'dart:io';

import 'app_data_paths.dart';
import 'device_vault_key.dart';
import 'secret_vault.dart';
import 'secure_storage_backend.dart';

/// Which store a secure-storage operation should go to right now.
enum SecureStorageChoice {
  /// The OS keyring, and it answered.
  keyring,

  /// The credential vault, because this install has one.
  vault,

  /// The OS keyring has worked here before and is not answering now, and no
  /// vault exists. The user has a keyring; it is locked. Nothing is stored
  /// and nothing is moved.
  keyringLocked,

  /// No keyring has ever worked here and there is no vault yet. A write in
  /// this state makes a device-encrypted vault and uses it.
  vaultSetupRequired,
}

/// Picks between the OS keyring and the credential vault, per operation.
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
///     fix is to unlock it. Moving their secrets into a vault would be
///     trading a keystore-backed store for a file, on the strength of a
///     transient failure. So this state refuses the write and says "unlock
///     it" — the app cannot downgrade, quietly or otherwise, because the only
///     route into a vault is [vaultSetupRequired], which this install can
///     never reach again once the keyring has been seen working even once.
///  4. **Neither → [vaultSetupRequired].** No keyring has ever worked here:
///     a snap with `password-manager-service` unconnected, a desktop with no
///     Secret Service daemon, a headless box. A [write] in this state makes
///     a device-encrypted vault on the spot and stores the credential in it.
///
/// The "has ever worked" bit is persisted, not remembered for the session:
/// a keyring that works only until the app restarts would otherwise be
/// enough to reach step 4 on the next launch.
///
/// ## Why step 4 does not ask
///
/// It used to refuse the write and offer to set an app passphrase, which put
/// a security decision in front of someone who had only wanted to add a
/// server, and presented a host that had in fact saved as a failure. Storing
/// the credential encrypted is the floor rather than something to opt into: a
/// device-encrypted vault needs nothing typed, protects the credential
/// against everything short of another process running as this same user, and
/// is strictly better than the alternative it replaces, which was not saving
/// the password at all. There is no mode to pick, nothing to set and nothing
/// to dismiss.
///
/// This changes nothing about step 3. Automatic device encryption is for
/// installs with no keyring at all, never a silent replacement for one that
/// works.
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
    DeviceVaultKey? deviceKey,
    SecureStorageState? state,
    Future<String?> Function()? requestUnlockPassphrase,
  })  :
        // ignore: prefer_initializing_formals
        _keyring = keyring,
        // ignore: prefer_initializing_formals
        _vault = vault,
        // ignore: prefer_initializing_formals
        _keyringAvailable = keyringAvailable,
        _deviceKey = deviceKey ?? DeviceVaultKey(),
        _state = state ?? SecureStorageState(),
        // ignore: prefer_initializing_formals
        _requestUnlockPassphrase = requestUnlockPassphrase;

  final SecureStorageBackend _keyring;
  final SecretVault _vault;
  final Future<bool> Function() _keyringAvailable;
  final DeviceVaultKey _deviceKey;
  final SecureStorageState _state;

  /// How a 1.4.1 passphrase vault asks for its passphrase when something
  /// needs a secret and the vault is sealed. Supplied by the app layer (see
  /// `main.dart`), the same shape as `SshService`'s `verifyHostKey` prompt:
  /// the service knows *when* to ask, the UI knows *how*. Null in tests and
  /// on any build with no way to prompt, in which case a sealed vault simply
  /// stays sealed. Never reached by a device-encrypted vault, which has no
  /// passphrase for anyone to type.
  final Future<String?> Function()? _requestUnlockPassphrase;

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
          );
        }
      case SecureStorageChoice.vault:
        await _requireUnlockedVault();
        await _vault.write(key, value);
      case SecureStorageChoice.keyringLocked:
        throw const SecureStorageUnavailableException(
          keyringLockedMessage,
          code: 'KeyringLocked',
        );
      case SecureStorageChoice.vaultSetupRequired:
        // No keyring, and none ever. Encrypt it here rather than refuse a
        // save the user asked for — see "Why step 4 does not ask" above.
        await _createDeviceVault();
        await _vault.write(key, value);
    }
  }

  /// Fails closed exactly like [FlutterSecureStorageBackend.read] does: a
  /// secret that cannot be reached reads as one that was never saved, and the
  /// caller ends up asking the user rather than connecting with a guess.
  ///
  /// A sealed vault is the one case worth an extra step first, because "there
  /// is nothing saved" would be a lie about a file we can see: it is opened
  /// with this device's key if there is one, and otherwise with the app's
  /// passphrase prompt if there is one. Declining the prompt, or a device key
  /// that has gone missing, still fails closed.
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

  Future<void> _createDeviceVault() async {
    final key = await _deviceKey.create();
    await _vault.createWithKey(key);
  }

  Future<void> _requireUnlockedVault() async {
    if (await _tryUnlockVault()) return;
    throw const SecureStorageUnavailableException(
      'The credential vault is locked. Enter its passphrase to save this '
      'credential.',
    );
  }

  /// One unlock at a time, shared by every caller that arrives while it is
  /// running. The host list asks for several hosts' credentials at once on a
  /// cold start, and without this each of them would stack up its own
  /// passphrase dialog.
  Future<bool>? _unlocking;

  /// True if the vault is open, opening it if it can be. A wrong passphrase
  /// is not retried here — the caller surfaces it and the user can try
  /// again — because a silent retry loop is how a prompt becomes impossible
  /// to cancel.
  Future<bool> _tryUnlockVault() {
    if (_vault.isUnlocked) return Future<bool>.value(true);
    return _unlocking ??= _unlockVault().whenComplete(() {
      _unlocking = null;
    });
  }

  Future<bool> _unlockVault() async {
    // This device's own key first, whenever there is one. Nothing records
    // which mode the vault is in: a key file that opens it *is* the mode, and
    // the vault's own header is the authority on the rest.
    final key = await _deviceKey.read();
    if (key != null) {
      try {
        await _vault.unlockWithKey(key);
        return true;
      } on SecretVaultException {
        // Stale — left beside a 1.4.1 passphrase vault. Ask for that instead.
      }
    }
    if (await _vault.isDeviceWrapped() ?? false) {
      // Device-sealed with no usable key file. There is no passphrase anyone
      // could type here, so this fails closed: reads come back empty and
      // nothing is written anywhere unprotected.
      return false;
    }
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

/// The one fact about *this install* that the selection rule has to remember
/// across launches: whether the OS keyring has ever answered.
///
/// A plain JSON file next to `hosts.json` in the app's private data
/// directory. It holds no secret — only whether a keyring was ever seen — so
/// it deliberately does not go through secure storage, which would be
/// circular anyway. Which protection is in use is *not* recorded here: that
/// is derived from what is actually on disk, because a second copy of a fact
/// is a second chance to be wrong about it.
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
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          return _cached = decoded['keyringEverAvailable'] == true;
        }
      }
    } catch (_) {
      // An unreadable marker means "we do not know". Answering "never seen
      // one" is the cautious direction only in the sense of not blocking a
      // user who genuinely has no keyring; a user who does have one reaches
      // step 2 of the rule and re-records it on the spot.
    }
    return _cached = false;
  }

  Future<void> recordKeyringAvailable() async {
    if (await keyringEverAvailable()) return;
    // In memory first: losing the write only costs a re-record on the next
    // launch, and the fact is true right now either way — not worth failing
    // a save the user asked for.
    _cached = true;
    try {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, dynamic>{'keyringEverAvailable': true}),
        flush: true,
      );
    } catch (_) {
      // See above.
    }
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await AppDataPaths.resolveDirectory();
    return _file = File('${dir.path}/$fileName');
  }
}
