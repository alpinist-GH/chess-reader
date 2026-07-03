import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../../core/models/move_token.dart';
import '../domain/move_resolver.dart';
import '../domain/san_tokenizer.dart';
import 'book_conversion.dart';

/// One spine chapter, preprocessed: every resolved move is wrapped in a
/// `<chessmove idx="...">` element and every recognized diagram image in a
/// `<chessdiagram fen="...">` element, both rendered as tappable widgets.
class EpubChapter {
  const EpubChapter({
    required this.title,
    required this.html,
    required this.moves,
  });

  final String title;

  /// XHTML with `<chessmove>` / `<chessdiagram>` wrappers and images inlined
  /// as data URIs.
  final String html;

  /// Resolved moves of this chapter, indexed by the `idx` attribute.
  final List<ResolvedMove> moves;
}

class EpubBook {
  const EpubBook({required this.title, required this.chapters});

  final String title;
  final List<EpubChapter> chapters;
}

/// Spine of an opened EPUB: the zip archive plus the ordered chapter hrefs.
class _Spine {
  _Spine(this.archive, this.title, this.hrefs);
  final Archive archive;
  final String title;
  final List<String> hrefs;
}

_Spine _openSpine(String path, Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);

  String readEntry(String name) {
    final file = archive.findFile(name) ??
        archive.findFile(name.replaceAll('\\', '/'));
    if (file == null) throw FormatException('EPUB entry not found: $name');
    return utf8.decode(file.content as List<int>, allowMalformed: true);
  }

  final container = XmlDocument.parse(readEntry('META-INF/container.xml'));
  final rootfiles = container.findAllElements('rootfile');
  final opfPath =
      rootfiles.isEmpty ? null : rootfiles.first.getAttribute('full-path');
  if (opfPath == null) {
    throw const FormatException('EPUB container.xml has no rootfile');
  }
  final opfDir = p.posix.dirname(opfPath);
  final opf = XmlDocument.parse(readEntry(opfPath));

  final title = opf.findAllElements('dc:title').isNotEmpty
      ? opf.findAllElements('dc:title').first.innerText
      : p.basenameWithoutExtension(path);

  final manifest = <String, ({String href, String type})>{};
  for (final item in opf.findAllElements('item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id != null && href != null) {
      manifest[id] = (href: href, type: item.getAttribute('media-type') ?? '');
    }
  }
  final hrefs = <String>[
    for (final ref in opf.findAllElements('itemref'))
      if (manifest[ref.getAttribute('idref')] case final item?)
        if (item.type.contains('xhtml') || item.type.contains('html'))
          p.posix.normalize(p.posix.join(opfDir, item.href)),
  ];
  return _Spine(archive, title, hrefs);
}

String _entryText(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file == null) throw FormatException('EPUB entry not found: $name');
  return utf8.decode(file.content as List<int>, allowMalformed: true);
}

/// Parses an EPUB into interactive chapters. Games span chapters, so the whole
/// book is tokenized and resolved as one stream. When [diagrams] is provided
/// (from the up-front conversion), the recognized board images are wrapped in
/// `<chessdiagram>` so the reader can show their FEN and load them on tap.
Future<EpubBook> loadEpubBook(String path, {BookConversion? diagrams}) async {
  final bytes = await File(path).readAsBytes();
  final spine = _openSpine(path, bytes);

  final documents = <dom.Document>[];
  final chapterNodeIndexes = <List<({dom.Text node, int start})>>[];
  final chapterTokens = <List<MoveToken>>[];

  for (final href in spine.hrefs) {
    final doc = html_parser.parse(_entryText(spine.archive, href));
    _inlineImages(doc, spine.archive, p.posix.dirname(href));
    final (text, nodeIndex) = _collectText(doc.body);
    documents.add(doc);
    chapterNodeIndexes.add(nodeIndex);
    chapterTokens.add(SanTokenizer.tokenize(text));
  }

  final allTokens = [for (final t in chapterTokens) ...t];
  final line = MoveResolver.resolve(allTokens);
  final resolvedByToken = {for (final r in line.moves) r.token: r};

  final chapters = <EpubChapter>[];
  for (var c = 0; c < documents.length; c++) {
    final tokensHere =
        chapterTokens[c].where(resolvedByToken.containsKey).toList();
    final moves = [for (final t in tokensHere) resolvedByToken[t]!];
    _wrapTokens(chapterNodeIndexes[c], tokensHere);
    if (diagrams != null) {
      _wrapDiagrams(documents[c], diagrams.diagramsFor(c));
    }
    final titleEl = documents[c].querySelector('h1, h2, h3, title');
    chapters.add(EpubChapter(
      title: titleEl?.text.trim().isNotEmpty == true
          ? titleEl!.text.trim()
          : 'Chapter ${c + 1}',
      html: documents[c].body?.innerHtml ?? '',
      moves: moves,
    ));
  }
  return EpubBook(title: spine.title, chapters: chapters);
}

/// For each chapter, the bytes of every `<img>` in document order (null where
/// the image can't be resolved). Used by the conversion pass to detect boards;
/// the index aligns with [loadEpubBook]'s `<img>` ordering.
Future<List<List<Uint8List?>>> epubChapterImages(String path) async {
  final bytes = await File(path).readAsBytes();
  final spine = _openSpine(path, bytes);
  final result = <List<Uint8List?>>[];
  for (final href in spine.hrefs) {
    final doc = html_parser.parse(_entryText(spine.archive, href));
    final dir = p.posix.dirname(href);
    result.add([
      for (final img in doc.querySelectorAll('img'))
        _resolveImageBytes(spine.archive, dir, img.attributes['src']),
    ]);
  }
  return result;
}

/// The bytes of the EPUB's cover image, or null if none can be found. Tries the
/// OPF `<meta name="cover" content="ID">` pointer, then the guide
/// `<reference type="cover">`, then the first image item in the manifest. A
/// guide reference may point at an XHTML wrapper page, in which case its first
/// `<img>` is used.
Future<Uint8List?> epubCoverImage(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    String readEntry(String name) => utf8.decode(
        archive.findFile(name)!.content as List<int>,
        allowMalformed: true);

    final container = XmlDocument.parse(readEntry('META-INF/container.xml'));
    final opfPath =
        container.findAllElements('rootfile').first.getAttribute('full-path')!;
    final opfDir = p.posix.dirname(opfPath);
    final opf = XmlDocument.parse(readEntry(opfPath));

    final manifest = <String, ({String href, String type})>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifest[id] =
            (href: href, type: item.getAttribute('media-type') ?? '');
      }
    }

    String? coverHref;
    for (final meta in opf.findAllElements('meta')) {
      if (meta.getAttribute('name') == 'cover') {
        final id = meta.getAttribute('content');
        if (id != null && manifest[id] != null) coverHref = manifest[id]!.href;
        break;
      }
    }
    if (coverHref == null) {
      for (final ref in opf.findAllElements('reference')) {
        if (ref.getAttribute('type') == 'cover') {
          coverHref = ref.getAttribute('href');
          break;
        }
      }
    }
    if (coverHref == null) {
      for (final item in manifest.values) {
        if (item.type.startsWith('image/')) {
          coverHref = item.href;
          break;
        }
      }
    }
    if (coverHref == null) return null;

    final resolved = p.posix.normalize(p.posix.join(opfDir, coverHref));
    final entry = archive.findFile(resolved);
    if (entry == null) return null;
    final lower = resolved.toLowerCase();
    if (lower.endsWith('.xhtml') ||
        lower.endsWith('.html') ||
        lower.endsWith('.htm')) {
      final doc = html_parser.parse(
          utf8.decode(entry.content as List<int>, allowMalformed: true));
      final src = doc.querySelector('img')?.attributes['src'];
      return _resolveImageBytes(archive, p.posix.dirname(resolved), src);
    }
    return Uint8List.fromList(entry.content as List<int>);
  } catch (_) {
    return null;
  }
}

const _blockTags = {'p', 'div', 'br', 'h1', 'h2', 'h3', 'li', 'td'};

(String, List<({dom.Text node, int start})>) _collectText(dom.Element? root) {
  final buffer = StringBuffer();
  final index = <({dom.Text node, int start})>[];
  void walk(dom.Node node) {
    if (node is dom.Text) {
      index.add((node: node, start: buffer.length));
      buffer.write(node.text);
      return;
    }
    if (node is dom.Element &&
        (node.localName == 'script' || node.localName == 'style')) {
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
    if (node is dom.Element && _blockTags.contains(node.localName)) {
      buffer.write('\n');
    }
  }

  if (root != null) walk(root);
  return (buffer.toString(), index);
}

void _wrapTokens(
  List<({dom.Text node, int start})> nodeIndex,
  List<MoveToken> tokens,
) {
  final byNode = <int, List<int>>{};
  for (var t = 0; t < tokens.length; t++) {
    for (var n = 0; n < nodeIndex.length; n++) {
      final entry = nodeIndex[n];
      final nodeEnd = entry.start + entry.node.text.length;
      if (tokens[t].start >= entry.start && tokens[t].end <= nodeEnd) {
        byNode.putIfAbsent(n, () => []).add(t);
        break;
      }
    }
  }

  byNode.forEach((n, tokenIndices) {
    final entry = nodeIndex[n];
    final node = entry.node;
    final parent = node.parentNode;
    if (parent == null) return;
    final text = node.text;

    final replacement = <dom.Node>[];
    var cursor = 0;
    for (final t in tokenIndices) {
      final localStart = tokens[t].start - entry.start;
      final localEnd = tokens[t].end - entry.start;
      if (localStart > cursor) {
        replacement.add(dom.Text(text.substring(cursor, localStart)));
      }
      replacement.add(dom.Element.tag('chessmove')
        ..attributes['idx'] = '$t'
        // Standard SAN (figurines mapped to letters), not the raw glyphs.
        ..append(dom.Text(tokens[t].san)));
      cursor = localEnd;
    }
    if (cursor < text.length) {
      replacement.add(dom.Text(text.substring(cursor)));
    }

    final insertAt = parent.nodes.indexOf(node);
    parent.nodes.removeAt(insertAt);
    parent.nodes.insertAll(insertAt, replacement);
  });
}

/// Wraps the board `<img>`s of a chapter (identified by their occurrence index,
/// stored as the diagram's `anchor`) in `<chessdiagram fen="...">`.
void _wrapDiagrams(dom.Document doc, List<ConvertedDiagram> diagrams) {
  if (diagrams.isEmpty) return;
  final imgs = doc.querySelectorAll('img');
  for (final d in diagrams) {
    if (d.anchor < 0 || d.anchor >= imgs.length) continue;
    final img = imgs[d.anchor];
    final parent = img.parentNode;
    if (parent == null) continue;
    final at = parent.nodes.indexOf(img);
    final wrapper = dom.Element.tag('chessdiagram')..attributes['fen'] = d.fen;
    parent.nodes.removeAt(at);
    wrapper.append(img);
    parent.nodes.insert(at, wrapper);
  }
}

void _inlineImages(dom.Document doc, Archive archive, String baseDir) {
  for (final img in doc.querySelectorAll('img')) {
    final src = img.attributes['src'];
    final data = _resolveImageBytes(archive, baseDir, src);
    if (data == null) continue;
    final ext = p.extension(src!).toLowerCase();
    final mime = switch (ext) {
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.svg' => 'image/svg+xml',
      _ => 'image/jpeg',
    };
    img.attributes['src'] = 'data:$mime;base64,${base64Encode(data)}';
  }
}

Uint8List? _resolveImageBytes(Archive archive, String baseDir, String? src) {
  if (src == null || src.startsWith('data:')) return null;
  final entryPath = p.posix.normalize(p.posix.join(baseDir, src));
  final file = archive.findFile(entryPath);
  if (file == null) return null;
  return Uint8List.fromList(file.content as List<int>);
}
