import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSession;

import 'remote_exec.dart';
import 'remote_path.dart';
import 'server_side_job.dart';
import 'shell_quote.dart';
import 'ssh_service.dart';

/// Which build of a command-line tool a server has.
///
/// Worth knowing because the same name hides different option sets: GNU
/// `find` has `-printf` and BusyBox's does not, GNU `grep` can end the names
/// it prints with NUL and BusyBox's cannot, and a BusyBox `tar` may have
/// been built without gzip or xz inside it. Anything not recognised is
/// [other] and gets the most portable form of every command.
enum ToolFlavour {
  gnu,
  busybox,
  bsd,
  infozip,
  other;

  static ToolFlavour parse(String text) => values.firstWhere(
        (v) => v.name == text,
        orElse: () => other,
      );
}

/// The archive a Compress makes.
enum ArchiveFormat {
  tarGz,
  zip;

  String get extension => switch (this) {
        ArchiveFormat.tarGz => '.tar.gz',
        ArchiveFormat.zip => '.zip',
      };

  String get label => switch (this) {
        ArchiveFormat.tarGz => 'tar.gz',
        ArchiveFormat.zip => 'zip',
      };
}

/// An archive Extract knows how to open, told apart by its name.
enum ArchiveKind {
  tar,
  tarGz,
  tarXz,
  zip;

  static const _suffixes = <(String, ArchiveKind)>[
    ('.tar.gz', ArchiveKind.tarGz),
    ('.tgz', ArchiveKind.tarGz),
    ('.tar.xz', ArchiveKind.tarXz),
    ('.txz', ArchiveKind.tarXz),
    ('.tar', ArchiveKind.tar),
    ('.zip', ArchiveKind.zip),
  ];

  /// The kind [name] claims to be, or null for anything else.
  static ArchiveKind? of(String name) {
    final lower = name.toLowerCase();
    for (final (suffix, kind) in _suffixes) {
      if (lower.length > suffix.length && lower.endsWith(suffix)) return kind;
    }
    return null;
  }

  /// [name] without the archive suffix: the folder an extract goes into
  /// by default. `site.tar.gz` → `site`.
  static String stem(String name) {
    final lower = name.toLowerCase();
    for (final (suffix, _) in _suffixes) {
      if (lower.length > suffix.length && lower.endsWith(suffix)) {
        return name.substring(0, name.length - suffix.length);
      }
    }
    return RemotePath.stem(name);
  }
}

/// What Extract does about a destination folder that is already there.
enum ExtractMode {
  /// The folder must not exist yet; the job refuses (exit 17) if it does.
  newFolder,

  /// Into the existing folder, leaving every file already in it alone.
  keepExisting,

  /// Into the existing folder, replacing files the archive also has.
  replaceExisting,
}

/// Exit codes the operation scripts use for refusals of their own, so a
/// refusal is worded as one rather than as the tool's failure.
class RemoteOpExit {
  const RemoteOpExit._();

  /// The name the operation would write is already taken.
  static const int exists = 17;

  /// The archive has entries that would land outside the folder.
  static const int unsafeArchive = 18;

  /// The archive could not be read at all.
  static const int unreadableArchive = 72;
}

/// What the server can do, as one probe found out.
///
/// Built from [probeCommand]'s output, once per session: which of the tools
/// behind the file browser's server-side actions exist, which build each
/// is, and whether `tar` has gzip and xz built in or needs the separate
/// programs piped to it. The browser offers an action only when this says
/// it will work, so a NAS without `zip` never shows "Compress to zip" and
/// a server with no shell at all (an SFTP-only account, a Windows box)
/// shows none of them.
class RemoteToolkit {
  const RemoteToolkit({
    this.tools = const {},
    this.tarGzip = false,
    this.tarXz = false,
  });

  /// Nothing available: the probe failed, or has not run.
  static const RemoteToolkit none = RemoteToolkit();

  /// The tools [probeCommand] asks about.
  static const List<String> probed = [
    'tar',
    'gzip',
    'xz',
    'zip',
    'unzip',
    'find',
    'grep',
    'cp',
    'chown',
  ];

  /// Every tool that was found, and which build it is.
  final Map<String, ToolFlavour> tools;

  /// `tar` handles `-z` itself.
  final bool tarGzip;

  /// `tar` handles `-J` itself.
  final bool tarXz;

  bool has(String tool) => tools.containsKey(tool);
  ToolFlavour? flavourOf(String tool) => tools[tool];

  bool get canCompressTarGz => has('tar') && (tarGzip || has('gzip'));

  /// Info-ZIP's `zip`; BusyBox has no `zip` applet, so most small boxes
  /// cannot make one.
  bool get canCompressZip => has('zip');

  List<ArchiveFormat> get compressFormats => [
        if (canCompressTarGz) ArchiveFormat.tarGz,
        if (canCompressZip) ArchiveFormat.zip,
      ];

  bool canExtract(ArchiveKind kind) => switch (kind) {
        ArchiveKind.tar => has('tar') && has('grep'),
        ArchiveKind.tarGz => has('tar') && has('grep') && (tarGzip || has('gzip')),
        ArchiveKind.tarXz => has('tar') && has('grep') && (tarXz || has('xz')),
        ArchiveKind.zip => has('unzip') && has('grep'),
      };

  bool get canSearch => has('find');
  bool get canSearchContents => has('find') && has('grep');
  bool get canDuplicate => has('cp');
  bool get canChangeOwner => has('chown');

  /// GNU `find`'s `-printf`, which reports each hit's type and size without
  /// a shell per batch.
  bool get findPrintf => tools['find'] == ToolFlavour.gnu;

  /// GNU `grep -l -Z`, which ends each name with NUL. BSD's `-Z` means
  /// something else entirely (decompress), and BusyBox has neither.
  bool get grepNulNames => tools['grep'] == ToolFlavour.gnu;

  /// `cp -a`. GNU and BusyBox have it; anything else gets `-pPR`, the POSIX
  /// spelling of the same copy (attributes kept, links copied as links).
  bool get cpArchive =>
      tools['cp'] == ToolFlavour.gnu || tools['cp'] == ToolFlavour.busybox;

  /// One line per tool found — `tool <name> <flavour>` — then `tar-gzip`
  /// and `tar-xz` when `tar` lists those options, then `end`.
  ///
  /// The build is read off `--version` (`-v` for the Info-ZIP pair), which
  /// GNU answers with its name, BusyBox with its usage banner, and the BSDs
  /// with an "illegal option" — plus the path's own `ls -l`, because on
  /// Alpine `/bin/tar` is a link to `/bin/busybox`. BSD is looked for
  /// before GNU: the BSDs' and macOS's grep call themselves "BSD grep, GNU
  /// compatible", and `-Z` means something else to them. A BusyBox shell
  /// built to prefer its own applets answers `command -v tar` with a bare
  /// `tar`, and those count too. Every probe reads
  /// `/dev/null`, so none of them can sit waiting for input.
  static const String probeCommand = r'''sh -c '
for t in tar gzip xz zip unzip find grep cp chown; do
  p=$(command -v "$t" 2>/dev/null) || continue
  [ -n "$p" ] || continue
  l=
  case "$p" in /*) l=$(ls -l "$p" 2>/dev/null) ;; esac
  case "$t" in
    zip|unzip) v=$("$t" -v </dev/null 2>&1 | head -n 3) ;;
    *) v=$("$t" --version </dev/null 2>&1 | head -n 3) ;;
  esac
  case "$l $v" in
    *busybox*|*BusyBox*) f=busybox ;;
    *bsdtar*|*libarchive*|*BSD*) f=bsd ;;
    *GNU*) f=gnu ;;
    *Info-ZIP*|*"This is Zip"*|*UnZip*) f=infozip ;;
    *) f=other ;;
  esac
  echo "tool $t $f"
  if [ "$t" = tar ]; then
    h=$(tar --help </dev/null 2>&1)
    if printf "%s\n" "$h" | grep -E -q "^[[:space:]]*-z([[:space:],]|\$)|-z, -j"; then echo tar-gzip; fi
    if printf "%s\n" "$h" | grep -E -q "^[[:space:]]*-J([[:space:],]|\$)|-j, -J"; then echo tar-xz; fi
  fi
done
echo end
' ''';

  static RemoteToolkit parse(String output) {
    final tools = <String, ToolFlavour>{};
    var gzip = false;
    var xz = false;
    for (final raw in const LineSplitter().convert(output)) {
      final line = raw.trim();
      if (line == 'tar-gzip') gzip = true;
      if (line == 'tar-xz') xz = true;
      final parts = line.split(' ');
      if (parts.length == 3 &&
          parts[0] == 'tool' &&
          probed.contains(parts[1])) {
        tools[parts[1]] = ToolFlavour.parse(parts[2]);
      }
    }
    return RemoteToolkit(
      tools: tools,
      tarGzip: gzip && tools.containsKey('tar'),
      tarXz: xz && tools.containsKey('tar'),
    );
  }

  /// Runs the probe over [transport]. Never throws: a server that cannot
  /// run it can do none of these things, which is [none].
  static Future<RemoteToolkit> probe(SessionTransport transport) async {
    try {
      final result = await RemoteExec.run(transport, probeCommand);
      return parse(result.stdout);
    } catch (_) {
      return none;
    }
  }
}

/// A path as an argument: absolute paths as they are, anything else behind
/// `./` — so no path, whatever its name, can be read as an option.
String _arg(String path) =>
    posixSingleQuote(path.startsWith('/') ? path : './$path');

/// A member name relative to the folder it is in, behind `./` for the same
/// reason. Refuses anything that is not a single name.
String _member(String name) {
  final problem = RemotePath.nameProblem(name);
  if (problem != null) throw ArgumentError.value(name, 'name', problem);
  return posixSingleQuote('./$name');
}

/// Fills `@NAME@` placeholders in one pass, so a value — already quoted —
/// is never searched for placeholders of its own.
String _fill(String template, Map<String, String> values) =>
    template.replaceAllMapped(RegExp(r'@([A-Z]+)@'), (m) {
      final value = values[m[1]];
      if (value == null) throw ArgumentError('no value for ${m[0]}');
      return value;
    });

/// The scripts behind the file browser's server-side actions, kept apart
/// from running them so the exact text — and its quoting of hostile names
/// — can be tested, and run through a real `sh` and a real BusyBox.
///
/// Every name and path reaches the shell through [posixSingleQuote], and
/// every one is shaped so it cannot be read as an option: an absolute path
/// starts with `/`, and a name in the current folder is passed as `./name`.
/// That holds for every tool here without relying on `--`, which `tar` and
/// `zip` do not all honour.
///
/// The mutating ones — compress, extract, duplicate, change owner — are
/// scripts for [ServerSideJob.launchScriptCommand], so they run to the end
/// whether or not the app is still there. Each starts `d="$1"`: the job
/// folder, for scratch files.
class RemoteFileCommands {
  const RemoteFileCommands._();

  /// Packs [names] (in [directory]) into [archiveName] beside them.
  ///
  /// Written under [partName] first and renamed into place only when the
  /// tool succeeded, so a failed or stopped run never leaves something that
  /// looks like the finished archive. Refuses (exit 17) when [archiveName]
  /// is taken, checked again just before the rename. Nor is it renamed once
  /// the job folder is gone, which is what stopping the job does first.
  ///
  /// `tar` stores links as links; `zip -y` is told to. Neither follows a
  /// link out of the folder being packed.
  static String compress({
    required String directory,
    required List<String> names,
    required String archiveName,
    required String partName,
    required ArchiveFormat format,
    required RemoteToolkit tools,
  }) {
    if (names.isEmpty) throw ArgumentError.value(names, 'names', 'empty');
    final members = names.map(_member).join(' ');
    final make = switch (format) {
      ArchiveFormat.tarGz when tools.tarGzip => 'tar -czf @PART@ $members',
      // A BusyBox built without gzip in tar: the separate gzip, with tar's
      // own status kept, since a pipeline only reports its last command.
      ArchiveFormat.tarGz => '{ tar -cf - $members; echo \$? > "\$d/st"; } '
          '| gzip -c > @PART@ && [ "\$(cat "\$d/st")" = 0 ]',
      ArchiveFormat.zip => 'zip -q -r -y @PART@ $members',
    };
    return _fill(r'''
d="$1"
cd @DIR@ || exit 71
if [ -e @OUT@ ] || [ -L @OUT@ ]; then echo "The archive's name is taken." >&2; exit 17; fi
if @MAKE@; then :; else s=$?; rm -f @PART@; exit $s; fi
if [ -e @OUT@ ] || [ -L @OUT@ ]; then rm -f @PART@; echo "The archive's name is taken." >&2; exit 17; fi
if [ -d "$d" ]; then :; else rm -f @PART@; exit 143; fi
mv -f @PART@ @OUT@''', {
      'DIR': _arg(directory),
      'OUT': _member(archiveName),
      'PART': _member(partName),
      'MAKE': _fill(make, {'PART': _member(partName)}),
    });
  }

  /// Unpacks [archivePath] into [destination].
  ///
  /// Lists the archive first and refuses it (exit 18) when any entry is
  /// absolute or climbs out with `..` — whatever a particular `tar` or
  /// `unzip` would have done about it. The check is on the listing's lines,
  /// so a name with a newline in it can only make it stricter. The whole
  /// listing — a pipeline, for the piped forms — goes to the file, and an
  /// empty one is refused rather than read as "nothing unsafe". GNU and
  /// BusyBox `tar` both say "removing leading …" when they would rewrite a
  /// name, and BusyBox lists the rewritten name, so that warning refuses it
  /// too.
  ///
  /// Links are held to the same rule: one whose target is absolute or
  /// climbs with `..` refuses the archive (exit 18). `tar -tv` shows each
  /// link's target beside its name, so the one listing covers both. A zip
  /// keeps its link targets as the links' contents: Info-ZIP's `zipinfo`
  /// says which entries are links, and each one's target is read with
  /// `unzip -p`. BusyBox's `unzip` lists neither, so there the links it
  /// made are checked once it is done, and any pointing out are removed
  /// (still exit 18). Every one of these `tar`s and `unzip`s makes an
  /// archive's own links last, after its files, so none of them writes
  /// through a link the same archive brought.
  ///
  /// [ExtractMode.newFolder] makes [destination] and refuses (exit 17) if
  /// something is already there; the merge modes go into the folder as it
  /// is, keeping or replacing the files the archive also has — unless it
  /// already holds a link pointing out of it, which BusyBox `tar` and
  /// either `unzip` would write through (exit 18).
  static String extract({
    required String archivePath,
    required ArchiveKind kind,
    required String destination,
    required ExtractMode mode,
    required RemoteToolkit tools,
  }) {
    // How the bytes reach tar: its own -z/-J when it has them, otherwise
    // the separate program on a pipe, its status kept in $d/st since a
    // pipeline reports only its last command. The mode letter always comes
    // first: bsdtar insists on it.
    final (String? flag, String? program) = switch (kind) {
      ArchiveKind.tarGz => (tools.tarGzip ? 'z' : null, 'gzip'),
      ArchiveKind.tarXz => (tools.tarXz ? 'J' : null, 'xz'),
      _ => ('', null),
    };
    final piped = kind != ArchiveKind.zip && flag == null;
    String viaTar(String mode, String rest) => piped
        ? '{ $program -dc < "\$a"; echo \$? > "\$d/st"; } | '
            'tar -${mode}f -$rest && [ "\$(cat "\$d/st")" = 0 ]'
        : 'tar -$mode${flag}f "\$a"$rest';

    final String list;
    final String unsafe;
    var links = ':';
    final String unpack;
    if (kind == ArchiveKind.zip) {
      // Info-ZIP lists one name a line. BusyBox has only `unzip -l`, a
      // table with the archive's own path in its header: its entry rows
      // are cut down to the name, which follows the time and three spaces.
      final infozip = tools.flavourOf('unzip') == ToolFlavour.infozip;
      list = infozip
          ? 'unzip -Z1 "\$a"'
          : '{ unzip -l "\$a"; echo \$? > "\$d/st"; } | '
              "sed -n 's/^ *[0-9][0-9]*  *[0-9][0-9-]*  *[0-9][0-9:]*   //p'"
              ' && [ "\$(cat "\$d/st")" = 0 ]';
      unsafe = r'^/|(^|/)\.\.(/|$)';
      final unzip = mode == ExtractMode.replaceExisting
          ? 'unzip -q -o "\$a" -d "\$t"'
          : 'unzip -q -n "\$a" -d "\$t"';
      if (infozip) {
        links = _zipLinks;
        unpack = unzip;
      } else {
        unpack = _fill(_unzipThenLinks, {'UNZIP': unzip});
      }
    } else {
      // A `tar -tv` row: mode, owner, size, date and time, then the name
      // and, for a link, ` -> ` or ` link to ` and its target. A name or
      // target that is absolute starts after a space; a `..` part sits
      // between spaces or slashes. Nothing else in a row looks like either,
      // so an odd owner or name can only make this refuse more.
      list = viaTar('tv', '');
      unsafe = r'(^| )/|(^|[ /])\.\.([ /]|$)';
      // Every tar replaces an existing file by default. `-k` keeps it, and
      // GNU, BusyBox and bsdtar all have it — but GNU and BusyBox then exit
      // non-zero for each file kept, which here is what was asked for. So
      // a failure whose every complaint is "File exists" is a success.
      unpack = mode == ExtractMode.keepExisting
          ? _fill(_keepExisting, {'TAR': viaTar('x', ' -k -C "\$t"')})
          : viaTar('x', ' -C "\$t"');
    }

    return _fill(_extractScript, {
      'ARCHIVE': _arg(archivePath),
      'DEST': _arg(destination),
      'LIST': list,
      'UNSAFE': posixSingleQuote(unsafe),
      'LINKS': links,
      'PREPARE': mode == ExtractMode.newFolder ? _makeFolder : _useFolder,
      'UNPACK': unpack,
    });
  }

  static const String _extractScript = r'''
d="$1"
a=@ARCHIVE@
t=@DEST@
[ -f "$a" ] || { echo "The archive is not there any more." >&2; exit 71; }
if { @LIST@; } > "$d/list" 2> "$d/lerr"; then :; else cat "$d/lerr" >&2; echo "The archive could not be read." >&2; exit 72; fi
if [ -s "$d/list" ]; then :; else cat "$d/lerr" >&2; echo "The archive is empty or could not be read." >&2; exit 72; fi
if grep -E -q @UNSAFE@ "$d/list" || grep -i -q "removing leading" "$d/lerr"; then echo "The archive has entries that would land outside the folder." >&2; exit 18; fi
@LINKS@
@PREPARE@
@UNPACK@''';

  /// Every link under `$t` whose target is absolute or climbs with `..`,
  /// as one `x` each — and, given `rm`, removed (the link, never what it
  /// points to). A link that cannot be read counts as one. Through
  /// `"$t/"`, so a destination that is itself a link is looked inside.
  static const String _outwardLinks =
      r'''find "$t/" -type l -exec sh -c 'm="$1"; shift; for l do r=$(readlink "$l") || r=/; case "$r" in /*|..|../*|*/..|*/../*) if [ "$m" = rm ]; then rm -f "$l"; fi; printf x;; esac; done' ssg-links''';

  /// Info-ZIP: the targets of the archive's links, read before anything is
  /// written. `zipinfo` rows are mode, version, system, size, type,
  /// method, date and time, then the name; a link's row starts with `l`.
  /// Each name goes back to `unzip -p` as a pattern, its `*`, `?`, `[`,
  /// `]` and `\` escaped. A target that comes back empty — a name
  /// `zipinfo` showed with `^J` for a control character, say — refuses.
  static const String _zipLinks = r'''
if unzip -Z "$a" > "$d/zi"; then :; else echo "The archive could not be read." >&2; exit 72; fi
b=$(sed -n 's/^l[^ ]*\(  *[^ ]*\)\{7\} //p' "$d/zi" | while IFS= read -r n; do r=$(unzip -p "$a" "$(printf '%s\n' "$n" | sed 's/[][\\*?]/\\&/g')" < /dev/null 2>/dev/null); case "$r" in ""|/*|..|../*|*/..|*/../*) printf x;; esac; done)
if [ -n "$b" ]; then echo "The archive has links that point outside the folder." >&2; exit 18; fi''';

  /// BusyBox `unzip`, whose listing shows no links: the ones it made that
  /// point out are removed once it is done. In a merge the folder held
  /// none before ([_useFolder] saw to that), so any found came from the
  /// archive.
  static final String _unzipThenLinks = '''
@UNZIP@
s=\$?
b=\$($_outwardLinks rm {} +)
if [ -n "\$b" ]; then echo "The archive had links that point outside the folder. They were removed." >&2; exit 18; fi
exit \$s''';

  static const String _makeFolder = r'''
if [ -e "$t" ] || [ -L "$t" ]; then echo "The folder already exists." >&2; exit 17; fi
mkdir "$t" || exit 73''';

  /// A merge goes ahead only into a folder with no link pointing out of
  /// it, and only once the whole of it could be looked through.
  static final String _useFolder = '''
if [ -d "\$t" ]; then
  if b=\$($_outwardLinks check {} +); then :; else echo "The folder could not be checked all the way through for links." >&2; exit 18; fi
  if [ -n "\$b" ]; then echo "The folder has links that point outside it, which the archive could write through." >&2; exit 18; fi
else mkdir "\$t" || exit 73; fi''';

  static const String _keepExisting = r'''
if { @TAR@; } 2> "$d/err"; then s=0; else s=$?; fi
if [ $s -ne 0 ] && ! grep -v -e "File exists" -e "Exiting with failure status" "$d/err" | grep -q .; then s=0; fi
cat "$d/err" >&2
exit $s''';

  /// Copies [source] to [destination] with everything kept — modes, times,
  /// links as links. Refuses (exit 17) if [destination] appeared meanwhile.
  ///
  /// Something turning up at [destination] between the check and the copy
  /// would have `cp` copy into it rather than to it. A folder is copied
  /// into one `mkdir` has just made — which fails if the name was taken in
  /// the meantime — as `source/.`, its contents and its own modes and
  /// times. Anything else goes with `-T`, where this `cp` has it, so a
  /// folder appearing at the name is refused rather than filled.
  static String duplicate({
    required String source,
    required String destination,
    required RemoteToolkit tools,
  }) {
    return _fill(r'''
d="$1"
if [ -e @DEST@ ] || [ -L @DEST@ ]; then echo "The copy's name is taken." >&2; exit 17; fi
if [ -d @SRC@ ] && [ ! -L @SRC@ ]; then
  if mkdir @DEST@; then :; elif [ -e @DEST@ ] || [ -L @DEST@ ]; then echo "The copy's name is taken." >&2; exit 17; else exit 73; fi
  cp @FLAGS@ @CONTENTS@ @DEST@
else
  T=
  if cp -T /dev/null "$d/t" 2>/dev/null; then T=-T; fi
  rm -f "$d/t"
  cp @FLAGS@ $T @SRC@ @DEST@
fi''', {
      'SRC': _arg(source),
      'CONTENTS': _arg('$source/.'),
      'DEST': _arg(destination),
      'FLAGS': tools.cpArchive ? '-a' : '-pPR',
    });
  }

  /// `chown -h [-R] -- owner[:group] paths…`.
  ///
  /// `-h` so a link has its own owner changed, never what it points to — a
  /// link in a tree being handed to another user must not hand over a file
  /// outside it. [owner] and [group] must pass [ownerProblem] first.
  static String changeOwner({
    required List<String> paths,
    required String owner,
    required String group,
    required bool recursive,
  }) {
    if (paths.isEmpty) throw ArgumentError.value(paths, 'paths', 'empty');
    final spec = ownerSpec(owner, group);
    if (spec == null) {
      throw ArgumentError('neither an owner nor a group was given');
    }
    return _fill(r'''
d="$1"
chown -h@R@ -- @SPEC@ @PATHS@''', {
      'R': recursive ? ' -R' : '',
      'SPEC': posixSingleQuote(spec),
      'PATHS': paths.map(_arg).join(' '),
    });
  }

  /// `owner`, `owner:group` or `:group`, or null when both are blank.
  static String? ownerSpec(String owner, String group) {
    final o = owner.trim();
    final g = group.trim();
    if (o.isEmpty && g.isEmpty) return null;
    return g.isEmpty ? o : '$o:$g';
  }

  static final RegExp _ownerName = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.@-]*\$?$');

  /// Why [name] cannot be an owner or group, or null when it can (blank is
  /// allowed: it means "leave that one").
  ///
  /// Stricter than the shell needs, since the value is quoted anyway: a
  /// name may not start with `-`, so it can never be read as an option,
  /// and may not hold `:` or a space, so it cannot change which part of
  /// `owner:group` it lands in.
  static String? ownerProblem(String name) {
    final value = name.trim();
    if (value.isEmpty) return null;
    if (value.length > 64) return 'That is too long for a user or group.';
    if (!_ownerName.hasMatch(value)) {
      return 'Letters, digits, "_", "-" and "." only, not starting with "-".';
    }
    return null;
  }

  /// Removes the one file at [path] — a stopped compress's part file.
  static String removeFile(String path) => 'rm -f ${_arg(path)}';

  /// `ls -ld` of [path]: whose it is now, for the change-owner dialog.
  static String ownerOf(String path) => 'ls -ld ${_arg(path)}';

  /// The owner and group out of [ownerOf]'s output, or null.
  static ({String owner, String group})? parseOwner(String output) {
    final line = const LineSplitter().convert(output).firstOrNull;
    if (line == null) return null;
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 4) return null;
    return (owner: fields[2], group: fields[3]);
  }

  /// A name-pattern `find` from [directory], optionally only files that
  /// contain [contains], streaming one record per hit, NUL-terminated.
  ///
  /// A pattern with no `*`, `?` or `[` in it is looked for anywhere in the
  /// name, the way a search box is expected to behave; one with them is
  /// used as the glob it is. Case is ignored unless [matchCase].
  ///
  /// Records are `<type> <size> <path>` (type `f`, `d`, `l`…, size `-`
  /// where unknown) or, from GNU `grep -lZ`, the bare path of a file. See
  /// [RemoteSearchParser].
  ///
  /// Wrapped so the search dies when this app lets go: `find` runs in the
  /// background, a `cat` on the channel's stdin waits beside it, and when
  /// the app closes stdin `cat` returns and kills it. Saved on fd 3 first,
  /// because a background job's own stdin is `/dev/null`.
  static String search({
    required String directory,
    required String pattern,
    String? contains,
    bool matchCase = false,
    required RemoteToolkit tools,
  }) {
    final text = contains ?? '';
    final glob = pattern.trim().isEmpty
        ? null
        : RegExp(r'[*?\[]').hasMatch(pattern)
            ? pattern.trim()
            : '*${pattern.trim()}*';
    final nameTest = glob == null
        ? ''
        : ' ${matchCase ? '-name' : '-iname'} ${posixSingleQuote(glob)}';
    final i = matchCase ? '' : ' -i';
    final dir = _arg(directory);

    final String find;
    if (text.isEmpty) {
      find = tools.findPrintf
          ? "find $dir -mindepth 1$nameTest -printf '%y %s %p\\0'"
          : 'find $dir -mindepth 1$nameTest -exec sh -c '
              '${posixSingleQuote(r'for f do if [ -L "$f" ]; then t=l; elif [ -d "$f" ]; then t=d; else t=f; fi; printf "%s - %s\0" "$t" "$f"; done')}'
              ' ssg {} +';
    } else {
      find = tools.grepNulNames
          ? 'find $dir -mindepth 1 -type f$nameTest -exec grep -l -Z -I -F$i '
              '-e ${posixSingleQuote(text)} {} +'
          : 'find $dir -mindepth 1 -type f$nameTest -exec sh -c '
              '${posixSingleQuote('p="\$1"; shift; for f do grep -q -F$i -e "\$p" "\$f" 2>/dev/null && printf "f - %s\\0" "\$f"; done; :')}'
              ' ssg ${posixSingleQuote(text)} {} +';
    }

    final script = _fill(r'''
exec 3<&0
@FIND@ 3<&- &
p=$!
( cat <&3 >/dev/null 2>&1; kill $p 2>/dev/null ) >/dev/null 2>&1 &
w=$!
exec 3<&-
wait $p
s=$?
kill $w 2>/dev/null
exit $s''', {'FIND': find});
    return 'sh -c ${posixSingleQuote(script)}';
  }

  /// [name] with ` copy` before its extension — ` copy 2`, ` copy 3` after
  /// that — skipping whatever [taken] says is there.
  ///
  /// The extension stays last so the copy still opens the same way; a
  /// folder, or a name with no extension, gets it on the end.
  static String copyName(
    String name,
    bool Function(String) taken, {
    bool isDirectory = false,
  }) {
    final archiveStem = ArchiveKind.of(name) == null ? null : ArchiveKind.stem(name);
    final stem = isDirectory
        ? name
        : archiveStem ?? RemotePath.stem(name);
    final ext = name.substring(stem.length);
    for (var n = 1; n < 10000; n++) {
      final candidate = n == 1 ? '$stem copy$ext' : '$stem copy $n$ext';
      if (!taken(candidate)) return candidate;
    }
    return '$stem copy ${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}

/// One hit from [RemoteFileCommands.search].
class RemoteSearchHit {
  const RemoteSearchHit({
    required this.path,
    required this.isDirectory,
    this.isLink = false,
    this.size,
  });

  final String path;
  final bool isDirectory;
  final bool isLink;
  final int? size;

  String get name => RemotePath.basename(path);
  String get folder => RemotePath.parent(path);
}

/// Turns the search's NUL-terminated stream into hits, whatever the chunk
/// boundaries — a record can be split across two SSH packets, or a single
/// UTF-8 character across two.
class RemoteSearchParser {
  final BytesBuilder _pending = BytesBuilder(copy: false);

  List<RemoteSearchHit> add(List<int> bytes) {
    final hits = <RemoteSearchHit>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0) continue;
      _pending.add(bytes.sublist(start, i));
      final hit = parseRecord(
        utf8.decode(_pending.takeBytes(), allowMalformed: true),
      );
      if (hit != null) hits.add(hit);
      start = i + 1;
    }
    if (start < bytes.length) _pending.add(bytes.sublist(start));
    return hits;
  }

  static RemoteSearchHit? parseRecord(String record) {
    if (record.isEmpty) return null;
    // A bare absolute path: GNU grep -lZ, always a regular file.
    if (record.startsWith('/')) {
      return RemoteSearchHit(path: record, isDirectory: false);
    }
    final first = record.indexOf(' ');
    if (first != 1) return null;
    final second = record.indexOf(' ', first + 1);
    if (second < 0) return null;
    final type = record[0];
    final path = record.substring(second + 1);
    if (!path.startsWith('/')) return null;
    return RemoteSearchHit(
      path: path,
      isDirectory: type == 'd',
      isLink: type == 'l',
      size: int.tryParse(record.substring(first + 1, second)),
    );
  }
}

/// A search running on the server, its hits arriving as they are found.
class RemoteSearch {
  RemoteSearch._(this._session, this._limit);

  /// Starts [command] (from [RemoteFileCommands.search]) on [transport],
  /// stopping it after [limit] hits.
  static Future<RemoteSearch> start(
    SessionTransport transport,
    String command, {
    int limit = 1000,
  }) async {
    final session = await transport.execute(command);
    return RemoteSearch._(session, limit).._listen();
  }

  final SSHSession _session;
  final int _limit;
  final _parser = RemoteSearchParser();
  final _hits = StreamController<List<RemoteSearchHit>>();
  final _errors = BytesBuilder();
  var _count = 0;
  var _stopped = false;
  final Completer<RemoteSearchEnd> _done = Completer<RemoteSearchEnd>();

  /// Hits, a batch per chunk that held any.
  Stream<List<RemoteSearchHit>> get hits => _hits.stream;

  /// How it ended: on its own, at [limit], or stopped.
  Future<RemoteSearchEnd> get done => _done.future;

  void _listen() {
    final outDone = Completer<void>();
    _session.stdout.listen(
      (chunk) {
        if (_stopped) return;
        var batch = _parser.add(chunk);
        if (_count + batch.length > _limit) {
          batch = batch.sublist(0, _limit - _count);
        }
        _count += batch.length;
        if (batch.isNotEmpty) _hits.add(batch);
        if (_count >= _limit) unawaited(_finish(limited: true));
      },
      onDone: outDone.complete,
      onError: (Object _) {
        if (!outDone.isCompleted) outDone.complete();
      },
      cancelOnError: false,
    );
    _session.stderr.listen(
      (chunk) {
        // Enough to count "Permission denied" lines; never the whole of a
        // search through / on a busy box.
        if (_errors.length < 64 * 1024) _errors.add(chunk);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
    unawaited(() async {
      int? code;
      try {
        code = await _session.waitForExit();
      } catch (_) {
        code = null;
      }
      await outDone.future
          .timeout(const Duration(seconds: 2), onTimeout: () {});
      await _finish(exitCode: code);
    }());
  }

  /// Stops the search on the server.
  Future<void> stop() => _finish(stopped: true);

  Future<void> _finish({
    bool limited = false,
    bool stopped = false,
    int? exitCode,
  }) async {
    if (_done.isCompleted) return;
    _stopped = true;
    final unreadable = const LineSplitter()
        .convert(utf8.decode(_errors.toBytes(), allowMalformed: true))
        .where((l) => l.toLowerCase().contains('permission denied'))
        .length;
    _done.complete(RemoteSearchEnd(
      count: _count,
      limited: limited,
      stopped: stopped,
      exitCode: exitCode,
      unreadableFolders: unreadable,
    ));
    if (!_hits.isClosed) unawaited(_hits.close());
    // stdin first: that is what the watchdog in the command waits on.
    try {
      await _session.stdin.close();
    } catch (_) {}
    try {
      _session.close();
    } catch (_) {}
  }
}

/// How a [RemoteSearch] ended.
class RemoteSearchEnd {
  const RemoteSearchEnd({
    required this.count,
    required this.limited,
    required this.stopped,
    required this.exitCode,
    required this.unreadableFolders,
  });

  final int count;

  /// Stopped at the limit: there may be more.
  final bool limited;
  final bool stopped;
  final int? exitCode;

  /// Folders `find` was not allowed into, which it says on stderr and
  /// otherwise passes over.
  final int unreadableFolders;
}

enum ServerOpState { succeeded, failed, cancelled, lost }

/// How a server-side operation ended.
class ServerOpOutcome {
  const ServerOpOutcome({
    required this.state,
    this.exitCode,
    this.log = '',
    this.message,
  });

  final ServerOpState state;
  final int? exitCode;

  /// The tail of what the script printed.
  final String log;

  /// Why it was lost, when [state] is [ServerOpState.lost].
  final String? message;

  bool get succeeded => state == ServerOpState.succeeded;
}

/// Runs one script as a detached job on the server and follows it.
///
/// [ServerSideJob.launchScriptCommand] starts it; while this app is still
/// around it asks [ServerSideJob.statusCommand] every [pollEvery] until it
/// ends, then removes the job folder. If the app goes away first, the job
/// finishes on its own and the next launch sweeps its folder up — the
/// operation is not lost, only the report of it.
class ServerOperation {
  ServerOperation({
    required this.transport,
    required this.script,
    this.afterCancel,
    this.pollEvery = const Duration(seconds: 1),
    String? jobId,
  }) : jobId = jobId ?? ServerSideJob.newId();

  /// Asked afresh for each step, so a session that reconnected mid-job is
  /// followed on its new connection.
  final SessionTransport Function() transport;
  final String script;

  /// Run once the job has been stopped, to tidy what it was writing — a
  /// compress removes its half-written archive.
  final String? afterCancel;

  final Duration pollEvery;
  final String jobId;

  var _cancelRequested = false;
  Completer<void>? _wake;

  bool get cancelRequested => _cancelRequested;

  /// Stops the job — its whole process group — at the next step.
  void cancel() {
    _cancelRequested = true;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<ServerOpOutcome> run() async {
    final ExecResult launch;
    try {
      launch = await RemoteExec.run(
        transport(),
        ServerSideJob.launchScriptCommand(jobId: jobId, script: script),
        timeout: const Duration(seconds: 30),
      );
    } catch (e) {
      return ServerOpOutcome(
        state: ServerOpState.failed,
        message: _messageOf(e),
      );
    }
    final launched = ServerSideJob.parseLaunch(launch.stdout);
    if (launched == null) {
      return ServerOpOutcome(
        state: ServerOpState.failed,
        exitCode: launch.exitCode,
        log: launch.stderr.trim(),
        message: 'The server could not start it.',
      );
    }

    var status = launched;
    var misses = 0;
    while (status.state == ServerJobState.running) {
      if (_cancelRequested) return _stop();
      final wake = _wake = Completer<void>();
      await Future.any([Future<void>.delayed(pollEvery), wake.future]);
      _wake = null;
      if (_cancelRequested) return _stop();
      try {
        final result =
            await RemoteExec.run(transport(), ServerSideJob.statusCommand(jobId));
        status = ServerSideJob.parseStatus(result.stdout);
        misses = 0;
      } catch (e) {
        // A dropped link while it runs: the job does not care, and the
        // session may well reconnect. Give it a while before giving up.
        if (++misses >= 30) {
          return ServerOpOutcome(
            state: ServerOpState.lost,
            message: 'Lost touch with the server. It carries on there by '
                'itself.',
          );
        }
      }
    }

    unawaited(_quietly(ServerSideJob.cleanupCommand(jobId)));
    if (status.state == ServerJobState.gone) {
      return ServerOpOutcome(
        state: ServerOpState.lost,
        log: status.log,
        message: 'It stopped on the server without finishing — the server '
            'may have restarted.',
      );
    }
    final code = status.exitCode ?? -1;
    return ServerOpOutcome(
      state: code == 0 ? ServerOpState.succeeded : ServerOpState.failed,
      exitCode: code,
      log: status.log,
    );
  }

  Future<ServerOpOutcome> _stop() async {
    await _quietly(ServerSideJob.cancelCommand(jobId));
    final tidy = afterCancel;
    if (tidy != null) await _quietly(tidy);
    return const ServerOpOutcome(state: ServerOpState.cancelled);
  }

  Future<void> _quietly(String command) async {
    try {
      await RemoteExec.run(transport(), command);
    } catch (_) {
      // Best effort: the sweep on the next launch catches a leftover.
    }
  }

  static String _messageOf(Object e) =>
      e is SshConnectionException ? e.message : e.toString();
}
