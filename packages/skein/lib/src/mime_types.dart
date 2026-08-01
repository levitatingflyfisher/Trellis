/// Content-Type by extension, covering the Flutter web build's asset set
/// (html, js, mjs, wasm, json, png, ico, otf, ttf, css) plus a couple of
/// extras a build occasionally emits (svg, txt, wav). Unknown extensions
/// fall back to `application/octet-stream` — never guessed.
const Map<String, String> _mimeByExtension = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.css': 'text/css',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain',
  '.wav': 'audio/wav',
};

/// The Content-Type for [path] by its extension (dotted, lowercased,
/// including compound ones like `.dart.wasm` — only the LAST dot-segment is
/// consulted, matching every static file server's convention).
String mimeTypeFor(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  final ext = path.substring(dot).toLowerCase();
  return _mimeByExtension[ext] ?? 'application/octet-stream';
}
