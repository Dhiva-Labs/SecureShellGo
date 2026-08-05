import 'package:flutter/material.dart';

import '../services/device_storage.dart';
import '../services/private_key_import.dart';

/// The dialog shown when a picked file is not a private key this app can
/// use, or when the picker itself failed.
///
/// Shared between the "Import key file" flow below and
/// `host_edit_screen.dart`'s "Install public key on server" errors — the
/// second of those never has a file name (there is no file involved), which
/// is why [fileName] is optional and the title falls back to "Could not
/// import key".
Future<void> showKeyFileErrorDialog(
  BuildContext context,
  String? fileName,
  String message,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        icon: Icon(Icons.error_outline, color: theme.colorScheme.error),
        title: Text(
          fileName == null
              ? 'Could not import key'
              : 'Could not import $fileName',
        ),
        content: Text(message, style: const TextStyle(height: 1.35)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}

/// The "Import key file" button, and everything behind it: opens
/// [deviceStorage]'s picker, reads whatever comes back as text (never
/// staging it to disk — see [DeviceStorage.pickTextFile]), and classifies it
/// through [classifyPrivateKeyPem] — the same check `SshService.connect` runs
/// — before trusting it enough to hand back to the caller.
///
/// Shared by `host_edit_screen.dart` and `quick_connect_screen.dart`, which
/// otherwise had the identical picker/classify/snackbar/error-dialog dance
/// twice over, differing only in which controller the result lands in and
/// which field gets focus afterwards — both left to the caller via
/// [onImported] and [onPassphraseNeeded].
class ImportKeyFileButton extends StatefulWidget {
  const ImportKeyFileButton({
    super.key,
    required this.deviceStorage,
    required this.onImported,
    this.onPassphraseNeeded,
  });

  final DeviceStorage deviceStorage;

  /// Called once a picked file parses as a private key — valid or
  /// passphrase-protected alike — never for a file [classifyPrivateKeyPem]
  /// rejects.
  final void Function(String fileName, String content, String keyType)
      onImported;

  /// Called right after [onImported], only when the key turned out to be
  /// encrypted, so the caller can move focus to its own passphrase field.
  final VoidCallback? onPassphraseNeeded;

  @override
  State<ImportKeyFileButton> createState() => _ImportKeyFileButtonState();
}

class _ImportKeyFileButtonState extends State<ImportKeyFileButton> {
  bool _importing = false;

  Future<void> _importKeyFile() async {
    if (_importing) return;
    setState(() => _importing = true);

    try {
      final picked = await widget.deviceStorage.pickTextFile(
        maxBytes: kMaxPrivateKeyImportBytes,
      );
      if (!mounted) return;
      if (picked == null) {
        // User backed out of the picker.
        return;
      }

      final result = classifyPrivateKeyPem(picked.content);
      switch (result.status) {
        case PrivateKeyImportStatus.valid:
          widget.onImported(picked.name, picked.content, result.keyType!);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Imported ${picked.name} — ${result.keyType}'),
            ),
          );
          break;
        case PrivateKeyImportStatus.passphraseProtected:
          widget.onImported(picked.name, picked.content, result.keyType!);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Imported ${picked.name} — ${result.keyType}, '
                'passphrase required',
              ),
            ),
          );
          widget.onPassphraseNeeded?.call();
          break;
        case PrivateKeyImportStatus.invalid:
          await showKeyFileErrorDialog(context, picked.name, result.message!);
          break;
      }
    } on DeviceStorageException catch (e) {
      if (!mounted) return;
      await showKeyFileErrorDialog(context, null, e.message);
    } catch (e) {
      if (!mounted) return;
      await showKeyFileErrorDialog(context, null, 'Could not read that file.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: _importing ? null : _importKeyFile,
        icon: _importing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_open_outlined, size: 18),
        label: Text(_importing ? 'Importing…' : 'Import key file'),
      ),
    );
  }
}
