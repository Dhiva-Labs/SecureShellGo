import 'package:flutter/material.dart';

/// Shows [snackBar] in place of whatever snackbar is already up, instead of
/// queueing behind it.
///
/// `ScaffoldMessenger.showSnackBar` plays snackbars one after another, each
/// for its full duration, so two routine messages in a row ("Downloading…",
/// then "Saved") hold the bottom of the window — over the shell prompt and
/// the key bar — for twice as long, saying something already stale. The
/// newest message is the only one worth reading.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showReplacingSnackBar(
  BuildContext context,
  SnackBar snackBar,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(snackBar);
}

/// [showReplacingSnackBar] for a plain message.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showReplacingSnack(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
  SnackBarAction? action,
}) =>
    showReplacingSnackBar(
      context,
      SnackBar(content: Text(message), duration: duration, action: action),
    );
