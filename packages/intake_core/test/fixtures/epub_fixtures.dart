// Programmatic EPUB fixtures — small valid zips built in memory with
// package:archive, so no binaries live in the repo.
import 'dart:typed_data';

import 'package:archive/archive.dart';

List<int> buildZip(Map<String, Object> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    if (content is String) {
      archive.addFile(ArchiveFile.string(name, content));
    } else {
      archive.addFile(ArchiveFile.bytes(name, content as List<int>));
    }
  });
  return ZipEncoder().encode(archive);
}

/// n filler words — enough prose to clear the donor's `wc<80` front-matter
/// heuristic when n >= 80.
String words(int n) => List.generate(n, (i) => 'w$i').join(' ');

String xhtml(String body) => '<?xml version="1.0" encoding="utf-8"?>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops">\n'
    '<head><title>t</title></head>\n<body>$body</body>\n</html>';

const containerXml = '<?xml version="1.0"?>\n'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles>\n</container>';

/// Fake PNG payload — magic bytes plus filler; never actually rendered.
final picBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5]);

/// A full EPUB3: OPF under OEBPS/, nav doc in a subdirectory (so TOC hrefs
/// exercise `resolveHref` with `../`), a semantic copyright page, three real
/// chapters (one titled only by an h3, one in a subdirectory with a figure,
/// code, table, and a footnote), and one image.
List<int> epub3() => buildZip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': containerXml,
      'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">test-book</dc:identifier>
<dc:title>The Test Book</dc:title>
</metadata>
<manifest>
<item id="nav" href="nav/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="front" href="front.xhtml" media-type="application/xhtml+xml"/>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
<item id="c3" href="text/c3.xhtml" media-type="application/xhtml+xml"/>
<item id="pic" href="images/pic.png" media-type="image/png"/>
</manifest>
<spine>
<itemref idref="front"/>
<itemref idref="c1"/>
<itemref idref="c2"/>
<itemref idref="c3"/>
</spine>
</package>''',
      'OEBPS/front.xhtml': xhtml(
          '<section epub:type="copyright-page"><p>All rights reserved. '
          '${words(100)}</p></section>'),
      'OEBPS/c1.xhtml': xhtml('<h1>Chapter One</h1>'
          '<p>The naïve opening paragraph. ${words(45)}</p>'
          '<p>A second paragraph. ${words(45)}</p>'),
      'OEBPS/c2.xhtml': xhtml('<h3>Section Two</h3>'
          '<p>Prose under an h3-only chapter. ${words(90)}</p>'),
      'OEBPS/text/c3.xhtml': xhtml('<h1>Chapter Three</h1>'
          '<p>Third chapter prose. ${words(90)}</p>'
          '<img src="../images/pic.png" alt="A pic"/>'
          '<pre>let x = 1;\nlet z = 3;</pre>'
          '<table><tr><td>cellA</td><td>cellB</td></tr></table>'
          '<div class="lang code">let y = 2;</div>'
          '<div class="equation">E = mc^2</div>'
          '<div epub:type="footnote"><p>FOOTNOTE text that must vanish</p></div>'),
      'OEBPS/nav/nav.xhtml': xhtml('<nav epub:type="toc"><ol>'
          '<li><a href="../c1.xhtml">One</a></li>'
          '<li><a href="../text/c3.xhtml#sec">Three</a>'
          '<ol><li><a href="../text/c3.xhtml#sub">Three-One</a></li></ol>'
          '</li></ol></nav>'),
      'OEBPS/images/pic.png': picBytes,
    });

/// An EPUB2: no nav doc, spine@toc points at an NCX with a nested navPoint.
List<int> epub2() => buildZip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': containerXml,
      'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>Old Book</dc:title>
</metadata>
<manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine toc="ncx">
<itemref idref="c1"/>
</spine>
</package>''',
      'OEBPS/toc.ncx': '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<navMap>
<navPoint id="n1"><navLabel><text>Start</text></navLabel>
<content src="c1.xhtml"/>
<navPoint id="n2"><navLabel><text>Deep</text></navLabel>
<content src="c1.xhtml#d"/></navPoint>
</navPoint>
</navMap>
</ncx>''',
      'OEBPS/c1.xhtml':
          xhtml('<h1>Only Chapter</h1><p>Some prose. ${words(90)}</p>'),
    });

/// A no-title EPUB with the OPF at the zip root: one chapter whose img src is
/// percent-encoded (`my%20pic.png` → entry `my pic.png`) and one img whose
/// target simply doesn't exist.
List<int> epubRootOpf() => buildZip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': '<?xml version="1.0"?>\n'
          '<container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
          '<rootfiles><rootfile full-path="content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles>\n'
          '</container>',
      'content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"></metadata>
<manifest>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine><itemref idref="c1"/></spine>
</package>''',
      'c1.xhtml': xhtml('<h1>Pics</h1><p>${words(90)}</p>'
          '<img src="my%20pic.png" alt="spaced"/>'
          '<img src="ghost.png" alt="missing"/>'),
      'my pic.png': picBytes,
    });

/// Spine of three: a "Table of Contents" heading page, a too-short section,
/// and one real chapter — exercising both cheap front-matter heuristics.
List<int> epubFrontMatterHeuristics() => buildZip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': containerXml,
      'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>Heuristics</dc:title>
</metadata>
<manifest>
<item id="tocpage" href="tocpage.xhtml" media-type="application/xhtml+xml"/>
<item id="short" href="short.xhtml" media-type="application/xhtml+xml"/>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine>
<itemref idref="tocpage"/>
<itemref idref="short"/>
<itemref idref="c1"/>
</spine>
</package>''',
      'OEBPS/tocpage.xhtml':
          xhtml('<h1>Table of Contents</h1><p>${words(100)}</p>'),
      'OEBPS/short.xhtml': xhtml('<p>${words(20)}</p>'),
      'OEBPS/c1.xhtml':
          xhtml('<h1>The Real Chapter</h1><p>${words(90)}</p>'),
    });

/// A zip that is not an EPUB at all.
List<int> zipWithoutContainer() => buildZip({'readme.txt': 'not an epub'});

/// container.xml present but with no rootfile element.
List<int> zipWithoutRootfile() => buildZip({
      'META-INF/container.xml': '<?xml version="1.0"?>'
          '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles></rootfiles></container>',
    });

/// rootfile points at an OPF that is not in the zip.
List<int> zipWithMissingOpf() => buildZip({
      'META-INF/container.xml': containerXml,
    });
