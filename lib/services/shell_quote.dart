/// POSIX single-quoting: wrap [value] in single quotes, and turn any embedded
/// single quote into `'\''` (close the quote, an escaped literal quote, reopen
/// the quote).
///
/// This is the only escaping a POSIX shell needs for an arbitrary byte string.
/// Unlike double quotes — where `$`, backtick, backslash and `!` all keep
/// meaning — nothing inside a single-quoted string is special except the
/// quote character itself, so a value that has been through here cannot start a
/// command substitution, expand a variable, or end the argument early no matter
/// what it contains.
///
/// Lifted out of `public_key_push.dart`, which had the only copy, once the
/// monitoring features needed the same rule for remote *paths* — a filename
/// is every bit as attacker-controlled as a key comment, and a second
/// hand-written copy of an escaping rule is how the two drift apart. There is
/// one definition, and `log_tail_test.dart` runs its output through a real
/// `sh` — including a filename that is itself four shell commands — to prove
/// it holds.
String posixSingleQuote(String value) =>
    "'${value.replaceAll("'", "'\\''")}'";
