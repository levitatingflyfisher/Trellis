import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Renders course prose: markdown + inline/blocks LaTeX ($...$, $$...$$),
/// tables, lists. Used for every *reading* surface (intake, answers, prompts).
class MdText extends StatelessWidget {
  const MdText(this.data, {super.key, this.style});
  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => GptMarkdown(
        data,
        style: style ?? Theme.of(context).textTheme.bodyMedium,
        // Never auto-fetch remote images. Course markdown is untrusted (imported
        // .ohcourse files), and the default renderer turns ![](https://…) into
        // an Image(NetworkImage(url)) — a silent outbound GET that a tracking
        // beacon could exploit. Render a placeholder instead of fetching.
        imageBuilder: (context, url, width, height) =>
            const Icon(Icons.image_outlined, size: 20),
      );
}

// Compiled once, not per call (this runs over multi-KB passages on rebuilds).
final _reBlockMath = RegExp(r'\$\$[\s\S]*?\$\$');
final _reInlineMath = RegExp(r'\$[^\$\n]+\$');
final _reCode = RegExp(r'`[^`]*`');
final _reMarkup = RegExp(r'[#*_>`|]');
final _reLatexCmd = RegExp(r'\\[a-zA-Z]+');
final _reSpaces = RegExp(r'[ \t]+');
final _reNewline = RegExp(r' ?\n ?');
final _strippedCache = <String, String>{};

/// Best-effort plain text for the RSVP streamer: equations and markdown markup
/// don't speed-read, so collapse math to a token and drop the symbols. The
/// rendered [MdText] card remains the surface for reading the math itself.
/// Memoized: it's a pure function of [md], re-asked on every intake rebuild.
String strippedForRsvp(String md) {
  final cached = _strippedCache[md];
  if (cached != null) return cached;
  var s = md;
  s = s.replaceAll(_reBlockMath, ' [equation] ');
  s = s.replaceAll(_reInlineMath, ' [eqn] ');
  s = s.replaceAll(_reCode, ' ');
  s = s.replaceAll(_reMarkup, ' ');
  s = s.replaceAll(_reLatexCmd, ' ');
  s = s.replaceAll(_reSpaces, ' ');
  s = s.replaceAll(_reNewline, '\n');
  return _strippedCache[md] = s.trim();
}
