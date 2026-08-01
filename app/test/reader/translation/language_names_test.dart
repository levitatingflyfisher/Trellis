import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/translation/language_names.dart';

/// languageDisplayName (Campaign 8 "Babel widens" Phase 1): the one
/// ISO-639-1-code -> English display name table the "Translate…" picker
/// and the work-language selector both read, so the two surfaces can
/// never drift into naming the same language two different ways.
void main() {
  group('languageDisplayName', () {
    test('names every language this campaign actually ships or discusses',
        () {
      expect(languageDisplayName('en'), 'English');
      expect(languageDisplayName('es'), 'Spanish');
      expect(languageDisplayName('de'), 'German');
      expect(languageDisplayName('ru'), 'Russian');
      expect(languageDisplayName('zh'), 'Chinese');
      expect(languageDisplayName('ja'), 'Japanese');
      expect(languageDisplayName('pt'), 'Portuguese');
      expect(languageDisplayName('fr'), 'French');
      expect(languageDisplayName('ko'), 'Korean');
    });

    test('an unknown code falls back to the code itself, uppercased — '
        'never a blank or a crash', () {
      expect(languageDisplayName('xx'), 'XX');
    });
  });
}
