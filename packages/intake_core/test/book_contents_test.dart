// A web book's contents page (owner, 17 Nov 2026). The shape follows
// the first real one: David Friedman's "Legal Systems Very Different
// from Ours", a page of chapter links to .docx files, some chapters
// linked twice, a shop link off the site and a link to the whole book as
// one file. The words here are stand-ins.
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

final page = Uri.parse('http://www.example.com/Legal%20Systems/Contents.htm');

String contents(String links) => '<html><head><title>Legal Systems Very '
    'Different From Ours</title></head><body><p>A late draft; also a '
    '<a href="https://shop.example.net/p/1">paperback</a>.</p>$links'
    '</body></html>';

void main() {
  test('a page of chapter links is a book, its chapters in order', () {
    final book = findBookContents(
        contents('<p><a href="Introduction.docx">Introduction</a></p>'
            '<p>1. <a href="Imperial%20Chinese%20Law.docx"> </a>'
            '<a href="Imperial%20Chinese%20Law.docx">Imperial Chinese Law</a></p>'
            '<p>2. <a href="Romani%20Law.docx">Romani Law</a></p>'
            '<p>3. <a href="Amish%20Law.docx">The Amish</a></p>'
            '<p>4. <a href="Jewish%20Law.docx">Jewish Law</a></p>'
            '<p>5. <a href="Islamic%20Law.docx">Islamic Law</a></p>'
            '<p><a href="Complete.docx">The whole book as one file</a></p>'),
        page)!;
    expect(book.title, 'Legal Systems Very Different From Ours');
    expect(book.contentsUrl, page);
    expect([for (final c in book.chapters) c.title],
        ['Introduction', 'Imperial Chinese Law', 'Romani Law', 'The Amish',
         'Jewish Law', 'Islamic Law']);
    expect(book.chapters[1].url.toString(),
        'http://www.example.com/Legal%20Systems/Imperial%20Chinese%20Law.docx');
  });

  test('chapter pages count as well as files, and a link to the page '
      'itself or to another site does not', () {
    final book = findBookContents(
        contents('<ol><li><a href="#top">Top</a></li>'
            '<li><a href="Contents.htm">Contents</a></li>'
            '<li><a href="ch1.html">One: the river rises</a></li>'
            '<li><a href="ch2.html#start">Two: the river falls</a></li>'
            '<li><a href="https://elsewhere.org/ch3.html">Three elsewhere</a></li>'
            '<li><a href="parts/ch3.html">Three: the river sleeps</a></li></ol>'),
        page)!;
    expect([for (final c in book.chapters) c.url.pathSegments.last],
        ['ch1.html', 'ch2.html', 'ch3.html']);
  });

  test('pictures, archives and PDFs are not chapters, nor are pages above '
      'the contents page’s folder', () {
    expect(
        findBookContents(
            contents('<a href="a.jpg">Picture one of the hall</a>'
                '<a href="b.zip">Archive of every chapter</a>'
                '<a href="c.pdf">A PDF of the second part</a>'
                '<a href="/index.html">Home page of the whole site</a>'
                '<a href="ch1.html">One</a>'),
            page),
        isNull);
  });

  test('an article with a few links in it is not a book', () {
    final prose = List.filled(40, 'The river rose and fell all winter. ').join();
    expect(
        findBookContents(
            '<html><body><p>$prose</p><p>See <a href="a.html">one</a>, '
            '<a href="b.html">two</a> and <a href="c.html">three</a>.</p>'
            '<p>$prose</p></body></html>',
            page),
        isNull);
  });

  test('fewer than three chapters is not a book', () {
    expect(
        findBookContents(
            contents('<a href="a.docx">Part one of two</a>'
                '<a href="b.docx">Part two of two</a>'),
            page),
        isNull);
  });

  test('a chapter linked without words is named by its file', () {
    final book = findBookContents(
        contents('<a href="Feud%20Law.docx"><img src="x.png"></a>'
            '<a href="b.docx">Second chapter of the book</a>'
            '<a href="c.docx">Third chapter of the book</a>'),
        page)!;
    expect(book.chapters.first.title, 'Feud Law');
  });
}
