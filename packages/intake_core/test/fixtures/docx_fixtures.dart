// Programmatic .docx fixtures: small valid zips built in memory, as the
// EPUB ones are, so no binaries live in the repo.
import 'package:archive/archive.dart';

const _ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
    'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
    'xmlns:v="urn:schemas-microsoft-com:vml"';

const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

List<int> zip(Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    archive.addFile(ArchiveFile.string(name, content));
  });
  return ZipEncoder().encode(archive);
}

String p(String text,
    {String? style, int? outlineLvl, int? num, int level = 0}) {
  final ppr = StringBuffer();
  if (style != null) ppr.write('<w:pStyle w:val="$style"/>');
  if (num != null) {
    ppr.write('<w:numPr><w:ilvl w:val="$level"/><w:numId w:val="$num"/></w:numPr>');
  }
  if (outlineLvl != null) ppr.write('<w:outlineLvl w:val="$outlineLvl"/>');
  return '<w:p>${ppr.isEmpty ? '' : '<w:pPr>$ppr</w:pPr>'}'
      '<w:r><w:t xml:space="preserve">$text</w:t></w:r></w:p>';
}

String raw(String xml) => xml;

String noteRef(int id) => '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/>'
    '</w:rPr><w:footnoteReference w:id="$id"/></w:r>';

String table(List<List<String>> rows) => '<w:tbl><w:tblPr/>'
    '${rows.map((r) => '<w:tr>${r.map((c) => '<w:tc><w:tcPr/>${p(c)}</w:tc>').join()}</w:tr>').join()}'
    '</w:tbl>';

String style(String id,
        {required String name, String? basedOn, int? outlineLvl}) =>
    '<w:style w:type="paragraph" w:styleId="$id"><w:name w:val="$name"/>'
    '${basedOn == null ? '' : '<w:basedOn w:val="$basedOn"/>'}'
    '${outlineLvl == null ? '' : '<w:pPr><w:outlineLvl w:val="$outlineLvl"/></w:pPr>'}'
    '</w:style>';

/// numId 1 is a bullet list; numId 2 numbers "1." with "a)" inside it.
String numbering() => '<w:numbering $_ns>'
    '<w:abstractNum w:abstractNumId="10"><w:lvl w:ilvl="0"><w:start w:val="1"/>'
    '<w:numFmt w:val="bullet"/><w:lvlText w:val=""/></w:lvl></w:abstractNum>'
    '<w:abstractNum w:abstractNumId="20">'
    '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>'
    '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2)"/></w:lvl>'
    '</w:abstractNum>'
    '<w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>'
    '<w:num w:numId="2"><w:abstractNumId w:val="20"/></w:num>'
    '</w:numbering>';

const _englishStyles = [
  ('Heading1', 'heading 1'),
  ('Heading2', 'heading 2'),
  ('Heading3', 'heading 3'),
  ('Title', 'Title'),
  ('TOC1', 'toc 1'),
];

List<int> docx({
  required List<String> body,
  String? title,
  Map<int, String> footnotes = const {},
  Map<String, String> links = const {},
  List<String> styles = const [],
  String? numbering,
  bool restartEachSection = false,
}) {
  final sect = restartEachSection
      ? '<w:sectPr><w:footnotePr><w:numRestart w:val="eachSect"/></w:footnotePr></w:sectPr>'
      : '<w:sectPr/>';
  final rels = StringBuffer(
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rIdS" Type="$_rel/styles" Target="styles.xml"/>');
  if (footnotes.isNotEmpty) {
    rels.write('<Relationship Id="rIdF" Type="$_rel/footnotes" Target="footnotes.xml"/>');
  }
  if (numbering != null) {
    rels.write('<Relationship Id="rIdN" Type="$_rel/numbering" Target="numbering.xml"/>');
  }
  links.forEach((id, href) => rels.write('<Relationship Id="$id" '
      'Type="$_rel/hyperlink" Target="$href" TargetMode="External"/>'));
  rels.write('</Relationships>');
  return zip({
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
    '_rels/.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="word/document.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
            '</Relationships>',
    'docProps/core.xml': '<cp:coreProperties '
        'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>${title ?? ''}</dc:title>'
        '<dc:creator>David Friedman</dc:creator></cp:coreProperties>',
    'word/document.xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<w:document $_ns><w:body>${body.join()}$sect</w:body></w:document>',
    'word/_rels/document.xml.rels': rels.toString(),
    'word/styles.xml': '<w:styles $_ns>'
        '${_englishStyles.map((s) => style(s.$1, name: s.$2)).join()}'
        '${styles.join()}</w:styles>',
    if (numbering != null) 'word/numbering.xml': numbering,
    if (footnotes.isNotEmpty)
      'word/footnotes.xml': '<w:footnotes $_ns>'
          '<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>'
          '<w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>'
          '${footnotes.entries.map((e) => '<w:footnote w:id="${e.key}"><w:p>'
              '<w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>'
              '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>'
              '<w:r><w:t xml:space="preserve"> ${e.value}</w:t></w:r></w:p></w:footnote>').join()}'
          '</w:footnotes>',
  });
}
