// Build a real Anki `.apkg` from a Trellis [Course], in pure Dart, on native
// platforms (Android/iOS/desktop/test VM). Mirrors the trellis-author skill's
// scripts/ohcourse_to_anki.py exactly: cloze→Cloze, qa/procedure/discrimination
// →Basic, one subdeck per node, course/node/`rung-N` tags, `$math$`→MathJax.
// Scheduling is left to Anki/FSRS — we only ship notes + cards.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models.dart';

bool get ankiExportSupported => true;

// ---- field rendering (mirror of render_html) ------------------------------
final _blockMath = RegExp(r'\$\$(.+?)\$\$', dotAll: true);
final _inlineMath = RegExp(r'\$([^$\n]+?)\$');
final _bold = RegExp(r'\*\*(.+?)\*\*', dotAll: true);
final _code = RegExp(r'`([^`]+?)`');
final _clozeNum = RegExp(r'\{\{c(\d+)::');
final _htmlTag = RegExp(r'<[^>]+>');

/// Render markdown/LaTeX source as Anki-safe HTML: escape, rewrite `$`-math to
/// MathJax delimiters Anki understands, lift `**bold**`/`` `code` ``, `\n`→`<br>`.
/// Cloze markers `{{cN::...}}` pass through untouched.
String renderHtml(String? s) {
  if (s == null || s.isEmpty) return '';
  var t = s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  t = t.replaceAllMapped(_blockMath, (m) => r'\[' + m[1]! + r'\]');
  t = t.replaceAllMapped(_inlineMath, (m) => r'\(' + m[1]! + r'\)');
  t = t.replaceAllMapped(_bold, (m) => '<b>${m[1]!}</b>');
  t = t.replaceAllMapped(_code, (m) => '<code>${m[1]!}</code>');
  return t.replaceAll('\n', '<br>');
}

String _stripHtml(String s) => s.replaceAll(_htmlTag, '');

/// Distinct cloze ordinals (0-based) present in a cloze Text field.
List<int> clozeOrds(String text) {
  final s = <int>{};
  for (final m in _clozeNum.allMatches(text)) {
    s.add(int.parse(m[1]!) - 1);
  }
  final l = s.toList()..sort();
  return l;
}

String _guidFor(String s) =>
    base64Url.encode(sha1.convert(utf8.encode(s)).bytes.sublist(0, 8)).replaceAll('=', '');

int _checksum(String firstField) =>
    int.parse(sha1.convert(utf8.encode(_stripHtml(firstField))).toString().substring(0, 8), radix: 16);

// ---- Anki collection scaffolding (genanki-faithful) -----------------------
const _basicCss =
    '.card {\n font-family: arial;\n font-size: 20px;\n text-align: left;\n color: black;\n background-color: white;\n}\n';
const _clozeCss = '$_basicCss.cloze {\n font-weight: bold;\n color: blue;\n}\n';
const _latexPre = '\\documentclass[12pt]{article}\n'
    '\\special{papersize=3in,5in}\n'
    '\\usepackage[utf8]{inputenc}\n'
    '\\usepackage{amssymb,amsmath}\n'
    '\\pagestyle{empty}\n'
    '\\setlength{\\parindent}{0in}\n'
    '\\begin{document}\n';
const _latexPost = '\\end{document}';

const _schema = '''
CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null,
  scm integer not null, ver integer not null, dty integer not null, usn integer not null,
  ls integer not null, conf text not null, models text not null, decks text not null,
  dconf text not null, tags text not null);
CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null,
  mod integer not null, usn integer not null, tags text not null, flds text not null,
  sfld integer not null, csum integer not null, flags integer not null, data text not null);
CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null,
  ord integer not null, mod integer not null, usn integer not null, type integer not null,
  queue integer not null, due integer not null, ivl integer not null, factor integer not null,
  reps integer not null, lapses integer not null, left integer not null, odue integer not null,
  odid integer not null, flags integer not null, data text not null);
CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null,
  ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null,
  time integer not null, type integer not null);
CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
CREATE INDEX ix_notes_usn on notes (usn);
CREATE INDEX ix_cards_usn on cards (usn);
CREATE INDEX ix_revlog_usn on revlog (usn);
CREATE INDEX ix_cards_nid on cards (nid);
CREATE INDEX ix_cards_sched on cards (did, queue, due);
CREATE INDEX ix_revlog_cid on revlog (cid);
CREATE INDEX ix_notes_csum on notes (csum);
''';

Map<String, dynamic> _field(String name, int ord) =>
    {'name': name, 'ord': ord, 'sticky': false, 'rtl': false, 'font': 'Arial', 'size': 20, 'media': <dynamic>[]};

Map<String, dynamic> _basicModel(int mid, int mod) => {
      'id': mid, 'name': 'Trellis Basic', 'type': 0, 'mod': mod, 'usn': -1, 'sortf': 0, 'did': 1,
      'latexPre': _latexPre, 'latexPost': _latexPost,
      'tmpls': [
        {'name': 'Card 1', 'ord': 0, 'qfmt': '{{Front}}', 'afmt': '{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}', 'did': null, 'bqfmt': '', 'bafmt': ''}
      ],
      'flds': [_field('Front', 0), _field('Back', 1)],
      'css': _basicCss, 'req': [[0, 'any', [0]]], 'tags': <dynamic>[], 'vers': <dynamic>[],
    };

Map<String, dynamic> _clozeModel(int mid, int mod) => {
      'id': mid, 'name': 'Trellis Cloze', 'type': 1, 'mod': mod, 'usn': -1, 'sortf': 0, 'did': 1,
      'latexPre': _latexPre, 'latexPost': _latexPost,
      'tmpls': [
        {'name': 'Cloze', 'ord': 0, 'qfmt': '{{cloze:Text}}', 'afmt': '{{cloze:Text}}<br>\n{{Back Extra}}', 'did': null, 'bqfmt': '', 'bafmt': ''}
      ],
      'flds': [_field('Text', 0), _field('Back Extra', 1)],
      'css': _clozeCss, 'req': [[0, 'any', [0]]], 'tags': <dynamic>[], 'vers': <dynamic>[],
    };

Map<String, dynamic> _deck(int did, String name, int mod) => {
      'id': did, 'name': name, 'mod': mod, 'usn': -1, 'lrnToday': [0, 0], 'revToday': [0, 0],
      'newToday': [0, 0], 'timeToday': [0, 0], 'collapsed': false, 'browserCollapsed': false,
      'desc': '', 'dyn': 0, 'conf': 1, 'extendNew': 0, 'extendRev': 0,
    };

const _dconf = {
  '1': {
    'id': 1, 'name': 'Default', 'mod': 0, 'usn': -1, 'maxTaken': 60, 'autoplay': true, 'timer': 0, 'replayq': true,
    'new': {'bury': false, 'delays': [1, 10], 'initialFactor': 2500, 'ints': [1, 4, 0], 'order': 1, 'perDay': 20, 'separate': true},
    'rev': {'bury': false, 'ease4': 1.3, 'fuzz': 0.05, 'ivlFct': 1, 'maxIvl': 36500, 'minSpace': 1, 'perDay': 200, 'hardFactor': 1.2},
    'lapse': {'delays': [10], 'leechAction': 1, 'leechFails': 8, 'minInt': 1, 'mult': 0},
  }
};

String _meta(RetrievalItem it) {
  final parts = <String>[];
  if (it.hints.isNotEmpty) {
    parts.add('<b>Hints</b><br>${it.hints.map(renderHtml).join('<br>')}');
  }
  final rubric = it is QaItem ? it.rubric : (it is ProcedureItem ? it.rubric : null);
  if (rubric != null && rubric.isNotEmpty) {
    parts.add('<b>Self-grade against</b><br>${renderHtml(rubric)}');
  }
  if (it.sources.isNotEmpty) {
    parts.add('<b>Sources</b><br>${it.sources.map(renderHtml).join('<br>')}');
  }
  return parts.join('<br><br>');
}

({String kind, List<String> fields}) _fieldsFor(RetrievalItem it) {
  String withExtra(String back) {
    final extra = _meta(it);
    return extra.isEmpty ? back : '$back<br><br>$extra';
  }

  switch (it) {
    case ClozeItem c:
      return (kind: 'cloze', fields: [renderHtml(c.text), _meta(it)]);
    case QaItem q:
      return (kind: 'basic', fields: [renderHtml(q.prompt), withExtra(renderHtml(q.answer))]);
    case DiscriminationItem d:
      final opts = [
        for (var i = 0; i < d.choices.length; i++) '${String.fromCharCode(65 + i)}. ${renderHtml(d.choices[i])}'
      ].join('<br>');
      final front = opts.isEmpty ? renderHtml(d.prompt) : '${renderHtml(d.prompt)}<br><br>$opts';
      var ans = (d.correctIndex >= 0 && d.correctIndex < d.choices.length) ? renderHtml(d.choices[d.correctIndex]) : '?';
      if (d.explanation != null) ans += '<br><br>${renderHtml(d.explanation)}';
      return (kind: 'basic', fields: [front, withExtra(ans)]);
    case ProcedureItem p:
      final steps = [for (var i = 0; i < p.steps.length; i++) '${i + 1}. ${renderHtml(p.steps[i])}'].join('<br>');
      return (kind: 'basic', fields: [renderHtml(p.prompt), withExtra(steps)]);
  }
}

/// Build the bytes of a real Anki `.apkg` (a zip of collection.anki2 + media)
/// for [course]. Pure: uses only a system temp file for the sqlite working DB,
/// so it runs under `flutter test` on the VM as well as on-device.
Uint8List buildApkgBytes(Course course) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final nowS = nowMs ~/ 1000;
  final root = course.title.isNotEmpty ? course.title : (course.id.isNotEmpty ? course.id : 'Trellis course');

  var next = nowMs;
  int id() => next++;
  final basicMid = id(), clozeMid = id();
  final models = {'$basicMid': _basicModel(basicMid, nowS), '$clozeMid': _clozeModel(clozeMid, nowS)};
  final parentDid = id();
  final decks = {'1': _deck(1, 'Default', nowS), '$parentDid': _deck(parentDid, root, nowS)};

  final notes = <List<Object?>>[];
  final cards = <List<Object?>>[];
  var pos = 0;
  for (final node in course.nodes) {
    final nodeTitle = (node.title.isNotEmpty ? node.title : node.id).replaceAll('::', '/');
    final nodeDid = id();
    decks['$nodeDid'] = _deck(nodeDid, '$root::$nodeTitle', nowS);
    for (final it in node.items) {
      final r = _fieldsFor(it);
      final mid = r.kind == 'cloze' ? clozeMid : basicMid;
      notes.add([
        id(), _guidFor('${course.id}:${it.id}'), mid, nowS, -1,
        ' ${course.id} ${node.id} rung-${it.rung} ',
        r.fields.join('\u001f'), _stripHtml(r.fields[0]), _checksum(r.fields[0]), 0, '',
      ]);
      final nid = notes.last[0];
      var ords = r.kind == 'cloze' ? clozeOrds(r.fields[0]) : <int>[0];
      if (ords.isEmpty) ords = <int>[0];
      for (final o in ords) {
        cards.add([id(), nid, nodeDid, o, nowS, -1, 0, 0, pos, 0, 0, 0, 0, 0, 0, 0, 0, '']);
        pos++;
      }
    }
  }

  final conf = {
    'nextPos': pos + 1, 'estTimes': true, 'activeDecks': [1], 'sortType': 'noteFld', 'timeLim': 0,
    'sortBackwards': false, 'addToCur': true, 'curDeck': 1, 'newSpread': 0, 'dueCounts': true,
    'curModel': '$basicMid', 'collapseTime': 1200,
  };

  final tmp = Directory.systemTemp.createTempSync('trellis_apkg');
  try {
    final colPath = '${tmp.path}/collection.anki2';
    final db = sqlite3.open(colPath);
    try {
      db.execute(_schema);
      db.execute('INSERT INTO col VALUES (1,?,?,?,?,?,?,?,?,?,?,?,?)',
          [nowS, nowMs, nowMs, 11, 0, 0, 0, jsonEncode(conf), jsonEncode(models), jsonEncode(decks), jsonEncode(_dconf), '{}']);
      final ns = db.prepare('INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)');
      for (final n in notes) {
        ns.execute(n);
      }
      ns.close();
      final cs = db.prepare('INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)');
      for (final c in cards) {
        cs.execute(c);
      }
      cs.close();
    } finally {
      db.close();
    }

    final colBytes = File(colPath).readAsBytesSync();
    final media = utf8.encode('{}');
    final archive = Archive()
      ..addFile(ArchiveFile('collection.anki2', colBytes.length, colBytes))
      ..addFile(ArchiveFile('media', media.length, media));
    final zip = ZipEncoder().encode(archive);
    return Uint8List.fromList(zip);
  } finally {
    // Remove the working dir on success AND on any failure above.
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Build the `.apkg` and write it to a temp file; returns its path (for sharing).
Future<String> exportApkgToTemp(Course course) async {
  final bytes = buildApkgBytes(course);
  final dir = await getTemporaryDirectory();
  final safe = course.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final file = File('${dir.path}/${safe.isEmpty ? 'course' : safe}-$stamp.apkg');
  await file.writeAsBytes(bytes);
  return file.path;
}
