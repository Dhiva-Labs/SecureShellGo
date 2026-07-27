import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

/// A download that finished and landed somewhere openable.
TransferTask saved(String name, {String? uri = 'content://downloads/0'}) {
  return TransferTask(
    id: name,
    name: name,
    remotePath: '/home/dev/$name',
    direction: TransferDirection.download,
  )
    ..status = TransferStatus.completed
    ..destination = 'Downloads/$name'
    ..destinationUri = uri;
}

void main() {
  /// Puts [snackBar] up on a bare app and returns once it is all the way in.
  Future<void> show(WidgetTester tester, SnackBar snackBar) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    ScaffoldMessenger.of(host).showSnackBar(snackBar);
    await tester.pumpAndSettle();
  }

  test('the announcement is not a persistent snack bar', () {
    // The regression in one line. `SnackBar` fills in `persist` from
    // `persist ?? action != null`, so an announcement carrying "Open" is
    // persistent unless it says otherwise — and a persistent bar's dismissal
    // timer fires and deliberately does nothing.
    final bar = buildDownloadSavedSnackBar(
      batch: [saved('notes.txt')],
      onOpen: (_) {},
      onShowAll: () {},
    );

    expect(bar.persist, isFalse);
  });

  testWidgets('one saved file names the file and offers Open', (tester) async {
    TransferTask? opened;
    await show(
      tester,
      buildDownloadSavedSnackBar(
        batch: [saved('notes.txt')],
        onOpen: (task) => opened = task,
        onShowAll: () {},
      ),
    );

    expect(find.text('Saved Downloads/notes.txt'), findsOneWidget);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened?.name, 'notes.txt');
  });

  testWidgets('it takes itself off the screen again', (tester) async {
    await show(
      tester,
      buildDownloadSavedSnackBar(
        batch: [saved('notes.txt')],
        onOpen: (_) {},
        onShowAll: () {},
      ),
    );
    expect(find.text('Saved Downloads/notes.txt'), findsOneWidget);

    // The bug as reported: this bar sat on screen for minutes, through folder
    // changes, Settings, the host list and reconnects, and came back after
    // being swiped away. Ten seconds of nobody touching anything is far past
    // the four it is allowed.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(find.text('Saved Downloads/notes.txt'), findsNothing);
  });

  testWidgets('a batch points at the transfers list, and also goes away',
      (tester) async {
    var showedAll = false;
    await show(
      tester,
      buildDownloadSavedSnackBar(
        batch: [saved('a.txt'), saved('b.txt')],
        onOpen: (_) {},
        onShowAll: () => showedAll = true,
      ),
    );

    expect(find.text('2 files saved to Downloads'), findsOneWidget);
    expect(find.text('Open'), findsNothing);

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(showedAll, isTrue);

    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('2 files saved to Downloads'), findsNothing);
  });

  testWidgets('a download with nowhere to point still announces itself',
      (tester) async {
    await show(
      tester,
      buildDownloadSavedSnackBar(
        batch: [saved('notes.txt', uri: null)],
        onOpen: (_) {},
        onShowAll: () {},
      ),
    );

    // No URI means no "Open" — the transfers list is what is left to offer.
    expect(find.text('Saved Downloads/notes.txt'), findsOneWidget);
    expect(find.text('Show'), findsOneWidget);
  });
}
