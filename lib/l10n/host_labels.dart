import '../models/host.dart';
import 'app_localizations.dart';

// The names the host screens show for the host model's enums, in the current
// language. Kept out of the enums themselves: `models/` stays free of
// Flutter, and their English `label`s are still what logs and the terminal's
// own notices print.

extension SshAuthMethodText on SshAuthMethod {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        SshAuthMethod.password => l10n.hostAuthPassword,
        SshAuthMethod.privateKey => l10n.hostAuthPrivateKey,
        SshAuthMethod.agent => l10n.hostAuthAgent,
      };
}

extension HostColorLabelText on HostColorLabel {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        HostColorLabel.red => l10n.hostColorRed,
        HostColorLabel.orange => l10n.hostColorOrange,
        HostColorLabel.yellow => l10n.hostColorYellow,
        HostColorLabel.green => l10n.hostColorGreen,
        HostColorLabel.teal => l10n.hostColorTeal,
        HostColorLabel.blue => l10n.hostColorBlue,
        HostColorLabel.purple => l10n.hostColorPurple,
        HostColorLabel.pink => l10n.hostColorPink,
      };
}

extension PersistentSessionText on PersistentSession {
  /// tmux and GNU screen are program names, the same in every language.
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        PersistentSession.off => l10n.hostSessionOff,
        PersistentSession.tmux || PersistentSession.screen => label,
      };
}

extension HostTransportText on HostTransport {
  /// SSH and Mosh are protocol names, the same in every language; this is
  /// here so every enum on the host form reads its name the same way.
  String localizedLabel(AppLocalizations l10n) => label;
}
