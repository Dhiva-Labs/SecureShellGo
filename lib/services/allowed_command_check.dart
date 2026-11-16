import '../models/host.dart';
import 'visible_text.dart';

/// Why an entry for a host's allowed-commands list was not taken, in terms
/// the editor turns into a plain sentence.
enum AllowedCommandProblem {
  /// Nothing but spaces.
  empty,

  /// Holds a line break: it would be several commands.
  lineBreak,

  /// Holds a control character, or one that is invisible, or a space that
  /// is not a plain space, or one that reorders the text.
  hiddenCharacter,

  /// Longer than [Host.maxAiAllowedCommandLength].
  tooLong,

  /// Already on the list.
  duplicate,

  /// The list already has [Host.maxAiAllowedCommands] entries.
  listFull,
}

/// Why [entry] would not be added to [existing], or null when it would be.
///
/// The authority is [Host.sanitizeAiAllowedCommands], the rule the store
/// applies; this only names the reason, and falls back to
/// [AllowedCommandProblem.hiddenCharacter] for anything that rule drops and
/// no more specific reason explains.
AllowedCommandProblem? allowedCommandProblem(
  String entry,
  List<String> existing,
) {
  final command = entry.trim();
  if (command.isEmpty) return AllowedCommandProblem.empty;
  if (existing.length >= Host.maxAiAllowedCommands) {
    return AllowedCommandProblem.listFull;
  }
  if (command.length > Host.maxAiAllowedCommandLength) {
    return AllowedCommandProblem.tooLong;
  }
  if (command.contains('\n') ||
      command.contains('\r') ||
      command.contains(' ') ||
      command.contains(' ')) {
    return AllowedCommandProblem.lineBreak;
  }
  if (existing.contains(command)) return AllowedCommandProblem.duplicate;
  if (Host.sanitizeAiAllowedCommands([command]).isEmpty ||
      visibleText(command).hasSurprises) {
    return AllowedCommandProblem.hiddenCharacter;
  }
  return null;
}
