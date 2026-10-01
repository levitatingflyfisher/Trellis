import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeNotesHtml', () {
    test('drops script, style, iframe and form with everything inside', () {
      final out = sanitizeNotesHtml('<p>Hi</p><script>alert(1)</script>'
          '<style>p{color:red}</style><iframe src="https://e.x"></iframe>'
          '<form action="/x"><input name="q"><button>Go</button></form>'
          '<p>Bye</p>');
      expect(out, '<p>Hi</p><p>Bye</p>');
    });

    test('entity-escaped script, decoded upstream into a real tag, is '
        'still dropped', () {
      // The parser decodes &lt;script&gt; into <script> before storage.
      expect(sanitizeNotesHtml('<script>steal()</script>Plain'), 'Plain');
    });

    test('keeps links, lists, paragraphs, bold, italic and line breaks', () {
      const html = '<p>See <a href="https://x.com/a">this</a></p>'
          '<ul><li><strong>One</strong></li><li><em>Two</em></li></ul>'
          '<ol><li><b>Three</b><br><i>four</i></li></ol>'
          '<blockquote>Quote</blockquote>';
      expect(
          sanitizeNotesHtml(html),
          '<p>See <a href="https://x.com/a">this</a></p>'
          '<ul><li><strong>One</strong></li><li><em>Two</em></li></ul>'
          '<ol><li><b>Three</b><br><i>four</i></li></ol>'
          '<blockquote>Quote</blockquote>');
    });

    test('strips event handlers, styles and every other attribute', () {
      expect(
          sanitizeNotesHtml('<p onclick="x()" style="color:red" class="c">'
              '<a href="https://x.com" onmouseover="y()" target="_blank">'
              'go</a></p>'),
          '<p><a href="https://x.com">go</a></p>');
    });

    test('a link to javascript: or data: loses its href', () {
      expect(
          sanitizeNotesHtml('<a href="javascript:alert(1)">bad</a> '
              '<a href="data:text/html,x">worse</a> '
              '<a href="mailto:hi@x.com">mail</a>'),
          'bad worse <a href="mailto:hi@x.com">mail</a>');
    });

    test('an http link with no host loses its href', () {
      expect(sanitizeNotesHtml('<a href="https:evil.test">odd</a> '
              '<a href="https://ok.test/">fine</a>'),
          'odd <a href="https://ok.test/">fine</a>');
    });

    test('a 1x1 tracking pixel is dropped; an image becomes its alt text', () {
      expect(
          sanitizeNotesHtml('<p>Hi<img src="https://t.x/p.gif" width="1" '
              'height="1" alt="pixel"></p>'
              '<p><img src="https://cdn.x/cover.jpg" alt="Cover art"></p>'
              '<p><img src="https://cdn.x/no-alt.jpg"></p>'),
          '<p>Hi</p><p>[Image: Cover art]</p>');
    });

    test('an image from a known beacon host is dropped even with alt', () {
      expect(
          sanitizeNotesHtml('<img src="https://www.google-analytics.com/'
              'collect?x" alt="ga">Text'),
          'Text');
    });

    test('unknown wrappers are unwrapped and headings kept as bold lines', () {
      expect(
          sanitizeNotesHtml('<div><h2>Links</h2><span>inside</span></div>'),
          '<p><strong>Links</strong></p>inside');
    });

    test('text is escaped on the way out', () {
      expect(sanitizeNotesHtml('<p>a &lt; b &amp; c</p>'),
          '<p>a &lt; b &amp; c</p>');
    });

    test('empty markup is null', () {
      expect(sanitizeNotesHtml('<script>x</script>  '), isNull);
      expect(sanitizeNotesHtml(''), isNull);
    });
  });

  group('notesPlainText', () {
    test('blocks become lines, inline markup flattens', () {
      expect(
          notesPlainText('<p>One <a href="https://x.com">two</a></p>'
              '<ul><li>three</li><li>four</li></ul>five<br>six'),
          'One two\nthree\nfour\nfive\nsix');
    });
  });
}
