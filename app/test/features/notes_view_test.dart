import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/works/notes_view.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  test('timestampAt reads h:mm:ss and mm:ss, and nothing else', () {
    expect(parseNoteTimestamps('Intro 1:02:03 then 12:34, not 99:99 or 3.5'),
        [
          (start: 6, end: 13, at: const Duration(hours: 1, minutes: 2, seconds: 3)),
          (start: 19, end: 24, at: const Duration(minutes: 12, seconds: 34)),
        ]);
    expect(parseNoteTimestamps('call 555:1234 or 10:30:45:00'), isEmpty);
  });

  testWidgets('renders paragraphs, list items, bold and links as text',
      (tester) async {
    await tester.pumpWidget(_host(const NotesView(
        html: '<p>Hello <strong>there</strong></p>'
            '<ul><li>One</li><li>Two</li></ul>'
            '<p><a href="https://x.test/a">A link</a></p>')));
    expect(find.textContaining('Hello there'), findsOneWidget);
    expect(find.textContaining('• One'), findsOneWidget);
    expect(find.textContaining('A link'), findsOneWidget);
  });

  testWidgets('a timestamp tap reports where to play from', (tester) async {
    Duration? at;
    await tester.pumpWidget(_host(NotesView(
        html: '<p>Chapters: 12:34 the comet</p>',
        onTimestamp: (d) => at = d)));
    await tester.tapOnText(find.textRange.ofSubstring('12:34'));
    expect(at, const Duration(minutes: 12, seconds: 34));
  });

  testWidgets('a time past the end of the episode is not a tap',
      (tester) async {
    Duration? at;
    await tester.pumpWidget(_host(NotesView(
        html: '<p>Doors at 10:30, chapter at 1:00</p>',
        onTimestamp: (d) => at = d,
        maxTimestamp: const Duration(minutes: 5))));
    await tester.tapOnText(find.textRange.ofSubstring('10:30'));
    expect(at, isNull);
    await tester.tapOnText(find.textRange.ofSubstring('1:00'));
    expect(at, const Duration(minutes: 1));
  });

  testWidgets('a link that is not http, https or mailto never opens, even '
      'from unsanitized HTML', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_host(NotesView(
        html: '<p><a href="intent://x#Intent;end">bad</a></p>',
        onOpenLink: (u) async => opened.add(u))));
    await tester.tapOnText(find.textRange.ofSubstring('bad'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-confirm')), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('a link tap asks first, naming the host, and opens only on '
      'yes', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_host(NotesView(
        html: '<p>See <a href="https://www.example.test/path?q=1">the map</a></p>',
        onOpenLink: (u) async => opened.add(u))));
    await tester.tapOnText(find.textRange.ofSubstring('the map'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-confirm')), findsOneWidget);
    expect(find.text('www.example.test'), findsOneWidget);
    expect(opened, isEmpty, reason: 'nothing opens before the answer');

    await tester.tap(find.byKey(const Key('link-cancel')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.tapOnText(find.textRange.ofSubstring('the map'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('link-open')));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://www.example.test/path?q=1')]);
  });

  testWidgets('long notes start folded with Show more', (tester) async {
    final long = List.generate(30, (i) => '<p>Paragraph $i of the notes, '
        'with enough words to take some room.</p>').join();
    await tester.pumpWidget(_host(NotesView(html: long, foldable: true)));
    expect(find.textContaining('Paragraph 0 '), findsOneWidget);
    expect(find.textContaining('Paragraph 29 '), findsNothing);
    await tester.tap(find.byKey(const Key('notes-more')));
    await tester.pump();
    expect(find.textContaining('Paragraph 29 '), findsOneWidget);
    expect(find.byKey(const Key('notes-less')), findsOneWidget);
  });
}
