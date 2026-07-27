import 'package:flutter/material.dart';

import '../theme.dart';

/// A red inline banner for a human-readable error, with an optional
/// collapsible "show details" section for the raw exception text.
///
/// Shared by every screen that surfaces an [SshConnectionException] —
/// originally the Phase 1 connect form, now the host edit screen and the
/// host list's connect flow.
class ErrorBanner extends StatefulWidget {
  const ErrorBanner({super.key, required this.message, this.details});

  final String message;
  final String? details;

  @override
  State<ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<ErrorBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, color: AppTheme.danger, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.message,
                  style: const TextStyle(height: 1.35),
                ),
              ),
            ],
          ),
          if (widget.details != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(_expanded ? 'Hide details' : 'Show details'),
              ),
            ),
            if (_expanded)
              SelectableText(
                widget.details!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
