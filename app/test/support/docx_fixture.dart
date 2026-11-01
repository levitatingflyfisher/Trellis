/// A small Word document for app tests; the parser's own cases are in
/// intake_core.
library;

import 'package:archive/archive.dart';

/// A small .docx: a chapter heading, a paragraph with a web link and a
/// footnote. The parser's own cases are in intake_core.
List<int> tinyDocx({String heading = 'Saga-Period Iceland'}) {
  const w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  const rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  final a = Archive()
    ..addFile(ArchiveFile.string('_rels/.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="r1" Type="$rel/officeDocument" Target="word/document.xml"/>'
        '</Relationships>'))
    ..addFile(ArchiveFile.string('word/_rels/document.xml.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rF" Type="$rel/footnotes" Target="footnotes.xml"/>'
        '<Relationship Id="rL" Type="$rel/hyperlink" Target="https://example.org/iceland" TargetMode="External"/>'
        '</Relationships>'))
    ..addFile(ArchiveFile.string('word/document.xml',
        '<w:document $w><w:body>'
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>$heading</w:t></w:r></w:p>'
        '<w:p><w:r><w:t xml:space="preserve">If you killed someone, his relatives sued </w:t></w:r>'
        '<w:hyperlink r:id="rL"><w:r><w:t>you</w:t></w:r></w:hyperlink><w:r><w:t>.</w:t></w:r>'
        '<w:r><w:footnoteReference w:id="1"/></w:r></w:p>'
        '</w:body></w:document>'))
    ..addFile(ArchiveFile.string('word/footnotes.xml',
        '<w:footnotes $w><w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r>'
        '<w:r><w:t xml:space="preserve"> Njal’s saga.</w:t></w:r></w:p></w:footnote></w:footnotes>'));
  return ZipEncoder().encode(a);
}

