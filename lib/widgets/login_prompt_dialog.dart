import 'package:flutter/material.dart';

import '../services/login_prompt.dart';
import '../theme.dart';

/// The login prompts and banners of one connect, shown over [_owner]'s
/// context for as long as it stays mounted.
///
/// Make one per connect and hand [answer] and [addBanner] to
/// `SshService.connect`. Banners are held until there is somewhere sensible
/// to show them — inside the next prompt dialog, or in a sheet from
/// [showUnseenBanners] once the login has succeeded — rather than popping
/// up in the middle of a handshake and then getting buried under the
/// session screen.
class LoginDialogs {
  LoginDialogs(this._owner);

  final State _owner;
  final _unseen = <ServerBanner>[];

  /// Fits `SshService.connect`'s `onBanner`.
  void addBanner(ServerBanner banner) => _unseen.add(banner);

  /// Fits `SshService.connect`'s `answerPrompts`. A screen that has gone
  /// away cancels, which fails the connect rather than leaving it waiting.
  Future<List<String>?> answer(LoginPrompt prompt) async {
    if (!_owner.mounted) return null;
    return showLoginPromptDialog(
      _owner.context,
      prompt,
      banners: _takeUnseen(),
    );
  }

  /// Shows the banners no prompt dialog has shown yet, and completes when
  /// the user dismisses them. Call it after a successful connect and before
  /// opening the session, so the server's notice comes first, as it would
  /// in a terminal.
  Future<void> showUnseenBanners() async {
    if (_unseen.isEmpty || !_owner.mounted) return;
    await showServerBannerSheet(_owner.context, _takeUnseen());
  }

  List<ServerBanner> _takeUnseen() {
    final banners = List.of(_unseen);
    _unseen.clear();
    return banners;
  }
}

/// Asks the questions in [prompt] and returns one answer per field, or null
/// if the user cancelled.
///
/// Not dismissible by tapping outside: a stray tap should not throw away a
/// login half way through a second factor. It closes itself if the server
/// gives up first (see [LoginPrompt.withdrawn]).
Future<List<String>?> showLoginPromptDialog(
  BuildContext context,
  LoginPrompt prompt, {
  List<ServerBanner> banners = const [],
}) {
  return showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LoginPromptDialog(prompt: prompt, banners: banners),
  );
}

/// Shows text a server sent before login, and completes once dismissed.
Future<void> showServerBannerSheet(
  BuildContext context,
  List<ServerBanner> banners,
) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final banner in banners) ...[
                        _BannerText(banner: banner),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LoginPromptDialog extends StatefulWidget {
  const _LoginPromptDialog({required this.prompt, required this.banners});

  final LoginPrompt prompt;
  final List<ServerBanner> banners;

  @override
  State<_LoginPromptDialog> createState() => _LoginPromptDialogState();
}

class _LoginPromptDialogState extends State<_LoginPromptDialog> {
  late final List<TextEditingController> _answers = [
    for (final _ in widget.prompt.fields) TextEditingController(),
  ];
  late final List<FocusNode> _focus = [
    for (final _ in widget.prompt.fields) FocusNode(),
  ];

  /// Which hidden fields the user has asked to see.
  late final List<bool> _revealed = [
    for (final _ in widget.prompt.fields) false,
  ];

  @override
  void initState() {
    super.initState();
    widget.prompt.withdrawn.then((_) => _closeIfStillOpen());
  }

  @override
  void dispose() {
    for (final controller in _answers) {
      controller.dispose();
    }
    for (final node in _focus) {
      node.dispose();
    }
    super.dispose();
  }

  /// The server gave up while this was on screen. Removes this route even
  /// if something has been pushed above it, rather than popping whatever
  /// happens to be on top.
  void _closeIfStillOpen() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _submit() {
    Navigator.of(context).pop([for (final c in _answers) c.text]);
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final challenge = prompt.challenge;
    final theme = Theme.of(context);
    final jumpTarget = prompt.jumpHostFor;

    return AlertDialog(
      icon: Icon(Icons.password, color: theme.colorScheme.primary, size: 32),
      title: Text('Sign in to ${prompt.host.displayName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              jumpTarget == null
                  ? prompt.host.target
                  : 'Jump host on the way to ${jumpTarget.displayName}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (prompt.savedPasswordRejected) ...[
              _Note(
                text: 'The server did not accept the saved password.',
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
            ],
            for (final banner in widget.banners) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: _BannerText(banner: banner),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (challenge.name.isNotEmpty) ...[
              Text(challenge.name, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
            ],
            if (challenge.instruction.isNotEmpty) ...[
              Text(
                challenge.instruction,
                style: const TextStyle(height: 1.35),
              ),
              const SizedBox(height: 12),
            ],
            for (var i = 0; i < prompt.fields.length; i++) ..._field(i),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  List<Widget> _field(int i) {
    final field = widget.prompt.fields[i];
    final isLast = i == widget.prompt.fields.length - 1;
    final hidden = !field.echo && !_revealed[i];
    final isPassword =
        KeyboardInteractiveResponder.looksLikePasswordPrompt(field.text);

    return [
      if (field.preamble.isNotEmpty) ...[
        Text(field.preamble, style: const TextStyle(height: 1.35)),
        const SizedBox(height: 8),
      ],
      TextField(
        controller: _answers[i],
        focusNode: _focus[i],
        autofocus: i == 0,
        obscureText: hidden,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: field.echo
            ? null
            : [isPassword ? AutofillHints.password : AutofillHints.oneTimeCode],
        textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
        onSubmitted: (_) =>
            isLast ? _submit() : _focus[i + 1].requestFocus(),
        decoration: InputDecoration(
          labelText: field.label.isEmpty ? 'Answer' : field.label,
          suffixIcon: field.echo
              ? null
              : IconButton(
                  tooltip: hidden ? 'Show' : 'Hide',
                  icon: Icon(
                    hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _revealed[i] = !_revealed[i]),
                ),
        ),
      ),
      if (!isLast) const SizedBox(height: 12),
    ];
  }
}

/// One server's banner: who sent it, then the text in a monospace box, since
/// banners are as often ASCII art as prose.
class _BannerText extends StatelessWidget {
  const _BannerText({required this.banner});

  final ServerBanner banner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jumpTarget = banner.jumpHostFor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          jumpTarget == null
              ? 'Message from ${banner.host.displayName}'
              : 'Message from ${banner.host.displayName} '
                  '(jump host for ${jumpTarget.displayName})',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            banner.text,
            style: const TextStyle(
              fontFamily: AppTheme.monoFontFamily,
              fontFamilyFallback: AppTheme.monoFontFamilyFallback,
              fontSize: 12.5,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: const TextStyle(height: 1.35)),
    );
  }
}
