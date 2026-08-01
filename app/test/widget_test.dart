import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

void main() {
  testWidgets('the shell boots to first-run profile creation', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    expect(find.text("Who's reading?"), findsOneWidget);
    // The debug ribbon overlapped the appbar's profile chip in dev builds
    // (the visual tour caught it on every screen).
    expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .debugShowCheckedModeBanner,
        isFalse);
  });
}
