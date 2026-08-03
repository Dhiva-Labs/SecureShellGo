import 'package:flutter/material.dart';

/// An icon and a line of explanatory text side by side — the shape this app
/// uses wherever a form or a dialog has to say something the user did not ask
/// about.
///
/// One widget rather than a hand-built [Row] per site. The three that existed
/// had already drifted: two icon sizes, two gaps, and one that forgot to dim
/// the text at all, so the same kind of remark looked like three different
/// kinds of remark.
class InlineHint extends StatelessWidget {
  const InlineHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
