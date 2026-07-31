/// How good a backup passphrase looks, for the hint under the field.
///
/// Four coarse buckets rather than a percentage or a bits-of-entropy figure,
/// because this cannot honestly measure either: it sees one string, not the
/// wordlist or the habit it came from, and a confident "78 bits" next to a
/// passphrase the user reuses everywhere would be a lie told with a progress
/// bar. Coarse and vague is the accurate register here.
enum PassphraseStrength {
  /// Below [BackupPassphrase.minLength]. The only bucket that blocks export —
  /// see [BackupPassphrase.isAcceptable].
  tooShort,
  weak,
  fair,
  strong;

  String get label => switch (this) {
        PassphraseStrength.tooShort => 'Too short',
        PassphraseStrength.weak => 'Weak',
        PassphraseStrength.fair => 'Fair',
        PassphraseStrength.strong => 'Strong',
      };
}

/// The passphrase rules for an encrypted backup.
///
/// Deliberately a minimum length and a hint, not a character-class mandate.
/// Forcing a symbol and a digit into a 12-character password is how users end
/// up with `Password1!`; four unrelated words beat it comfortably and would
/// fail such a rule. So length is the only hard gate, and everything else is
/// advice.
///
/// Nothing here stores, logs or hashes the passphrase. It exists in memory
/// for the length of one export or import and is never written anywhere —
/// there is no "remember this passphrase" and there is not going to be one,
/// because a remembered backup passphrase turns the file back into something
/// the device can open on its own.
class BackupPassphrase {
  const BackupPassphrase._();

  /// The floor for a passphrase protecting a file that may contain every
  /// server password the user owns. Argon2id makes each guess expensive, but
  /// it cannot rescue a six-character passphrase from a wordlist.
  static const int minLength = 12;

  /// Whether [passphrase] clears the hard gate. Strength below [strong] is a
  /// nudge, not a refusal — the user is entitled to decide their own trade.
  static bool isAcceptable(String passphrase) =>
      passphrase.length >= minLength;

  static PassphraseStrength strengthOf(String passphrase) {
    if (passphrase.length < minLength) return PassphraseStrength.tooShort;

    // 'aaaaaaaaaaaaaaaa' is sixteen characters and worthless. Distinct
    // characters is a crude proxy for that, but it catches the held-down-key
    // passphrase without punishing a legitimate short-word passphrase.
    if (passphrase.split('').toSet().length < 5) return PassphraseStrength.weak;

    var classes = 0;
    if (RegExp(r'[a-z]').hasMatch(passphrase)) classes++;
    if (RegExp(r'[A-Z]').hasMatch(passphrase)) classes++;
    if (RegExp(r'[0-9]').hasMatch(passphrase)) classes++;
    if (RegExp(r'[^a-zA-Z0-9]').hasMatch(passphrase)) classes++;

    var score = 0;
    if (passphrase.length >= 16) score++;
    if (passphrase.length >= 24) score++;
    if (classes >= 3) score++;
    if (classes >= 4) score++;

    if (score >= 3) return PassphraseStrength.strong;
    if (score == 2) return PassphraseStrength.fair;
    return PassphraseStrength.weak;
  }

  /// The line shown under the field. Says what would actually help rather
  /// than just naming the bucket.
  static String hintFor(String passphrase) =>
      switch (strengthOf(passphrase)) {
        PassphraseStrength.tooShort =>
          'Use at least $minLength characters.',
        PassphraseStrength.weak =>
          'Weak. A few unrelated words are stronger than one long one.',
        PassphraseStrength.fair => 'Fair. Longer is the easiest improvement.',
        PassphraseStrength.strong => 'Strong.',
      };
}
