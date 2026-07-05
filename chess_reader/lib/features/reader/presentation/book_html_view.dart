import 'dart:convert';
import 'dart:typed_data';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../core/persistence/library_store.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/state/game_session.dart';
import '../../vision/domain/board_annotations.dart';
import '../data/epub_book.dart';
import '../state/book_providers.dart';
import '../state/reader_nav.dart';

/// A scrollable list of [EpubChapter]s rendered with [ChapterHtml]. Shared by
/// the EPUB reader and the PDF "reading view". Handles resume-to-last,
/// current-chapter tracking, and jump-to-chapter requests (TOC/search/
/// bookmarks) via [epubJumpProvider].
class HtmlChapterList extends ConsumerStatefulWidget {
  const HtmlChapterList({
    super.key,
    required this.path,
    required this.chapters,
    required this.sourceKeyPrefix,
  });

  final String path;
  final List<EpubChapter> chapters;

  /// 'ch' for EPUB chapters, 'pg' for PDF pages.
  final String sourceKeyPrefix;

  @override
  ConsumerState<HtmlChapterList> createState() => _HtmlChapterListState();
}

class _HtmlChapterListState extends ConsumerState<HtmlChapterList> {
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_onScroll);
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;
    final top = positions
        .where((p) => p.itemTrailingEdge > 0)
        .reduce((a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b)
        .index;
    ref.read(currentPageProvider.notifier).set(top + 1);
    ref.read(libraryStoreProvider.notifier).recordPage(widget.path, top + 1);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(epubJumpProvider, (_, target) {
      if (target != null && _itemScroll.isAttached) {
        _itemScroll.scrollTo(
            index: target.clamp(0, widget.chapters.length - 1),
            duration: const Duration(milliseconds: 300));
        ref.read(epubJumpProvider.notifier).consumed();
      }
    });

    final resume =
        ref.read(libraryStoreProvider.notifier).lastPageFor(widget.path);
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScroll,
      itemPositionsListener: _positions,
      initialScrollIndex: resume != null
          ? (resume - 1).clamp(0, widget.chapters.length - 1)
          : 0,
      itemCount: widget.chapters.length,
      itemBuilder: (context, i) => ChapterHtml(
        chapter: widget.chapters[i],
        sourceKey: '${widget.sourceKeyPrefix}$i',
      ),
    );
  }
}

/// Renders one [EpubChapter] (used for both EPUB chapters and PDF "pages" in
/// the HTML reading view). Diagrams are pulled OUT of the flutter_html render
/// and shown as native [_DiagramTile] widgets interleaved with the prose; moves
/// are rendered inline as a `TextSpan` with a `TapGestureRecognizer`.
///
/// Why not embed both as flutter_html widgets? flutter_html turns a
/// `TagExtension` widget into a `WidgetSpan`, and taps on a `GestureDetector`
/// inside a `WidgetSpan`-in-`RichText` are dropped most of the time (the same
/// gesture-arena problem the PDF reader sidesteps with a real overlay). The
/// library itself only delivers reliable taps through a `TextSpan` recognizer
/// (see its `<a>` handling), so moves use that and diagrams become real widgets.
///
/// [sourceKey] scopes move-selection highlighting to this chapter/page.
class ChapterHtml extends ConsumerStatefulWidget {
  const ChapterHtml({
    super.key,
    required this.chapter,
    required this.sourceKey,
  });

  final EpubChapter chapter;
  final Object sourceKey;

  @override
  ConsumerState<ChapterHtml> createState() => _ChapterHtmlState();
}

class _ChapterHtmlState extends ConsumerState<ChapterHtml> {
  /// Prose (HTML) segments interleaved with the diagrams extracted from them.
  late List<_Segment> _segments = _splitSegments(widget.chapter.html);

  /// One persistent tap recognizer per move index, reused across rebuilds (a
  /// recognizer must outlive the span it drives) and disposed here.
  final Map<int, TapGestureRecognizer> _moveTaps = {};

  @override
  void didUpdateWidget(ChapterHtml old) {
    super.didUpdateWidget(old);
    if (!identical(old.chapter, widget.chapter)) {
      _segments = _splitSegments(widget.chapter.html);
      _disposeTaps();
    }
  }

  @override
  void dispose() {
    _disposeTaps();
    super.dispose();
  }

  void _disposeTaps() {
    for (final t in _moveTaps.values) {
      t.dispose();
    }
    _moveTaps.clear();
  }

  TapGestureRecognizer _tapFor(int idx) => _moveTaps.putIfAbsent(
        idx,
        () => TapGestureRecognizer()
          ..onTap = () => ref
              .read(activeLineProvider.notifier)
              .select(widget.chapter.moves, idx, widget.sourceKey),
      );

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(activeLineProvider);
    final selectedIdx = active != null && active.sourceKey == widget.sourceKey
        ? active.index
        : -1;
    final highlight = Theme.of(context).colorScheme.primary;
    final textScale = ref.watch(settingsProvider.select((s) => s.textScale));

    // Re-created each build so the highlight tracks the selected move; the
    // recognizer it points at is cached, so taps keep working across rebuilds.
    final moveExt = TagExtension.inline(
      tagsToExtend: const {'chessmove'},
      builder: (ctx) {
        final idx = int.tryParse(ctx.attributes['idx'] ?? '') ?? -1;
        final text = ctx.element?.text ?? '';
        if (idx < 0) return TextSpan(text: text);
        final selected = idx == selectedIdx;
        return TextSpan(
          text: text,
          recognizer: _tapFor(idx),
          style: TextStyle(
            color: highlight,
            fontWeight: FontWeight.w600,
            backgroundColor:
                highlight.withValues(alpha: selected ? 0.30 : 0.08),
          ),
        );
      },
    );
    final imgExt = TagExtension(
      tagsToExtend: const {'img'},
      builder: (ctx) {
        final bytes = _decodeDataImage(ctx.attributes['src'] ?? '');
        return bytes == null ? const SizedBox.shrink() : Image.memory(bytes);
      },
    );

    final children = <Widget>[];
    for (final seg in _segments) {
      if (seg.fen != null) {
        if (seg.fen!.isNotEmpty) {
          children.add(_DiagramTile(fen: seg.fen!, ann: seg.ann));
        } else if (seg.imgBase64 != null) {
          // Unreconstructable training diagram: show it as printed.
          children.add(_FallbackDiagramTile(pngBase64: seg.imgBase64!));
        }
      } else if (seg.html!.trim().isNotEmpty) {
        children.add(Html(
          data: seg.html,
          style: {
            'body': Style(
              fontSize: FontSize(16 * textScale),
              margin: Margins.zero,
              padding: HtmlPaddings.zero,
            ),
          },
          extensions: [moveExt, imgExt],
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// A prose run (`html`) or an extracted diagram (`fen`, possibly empty for an
/// as-printed fallback); exactly one of the two is set.
class _Segment {
  const _Segment.html(this.html)
      : fen = null,
        ann = '',
        imgBase64 = null;
  const _Segment.diagram(this.fen, {this.ann = '', this.imgBase64})
      : html = null;

  final String? html;
  final String? fen;

  /// Encoded training annotations (see `decodeAnnotations`); '' when none.
  final String ann;

  /// The diagram's crop PNG (base64), used only when [fen] is empty — an
  /// unreconstructable training diagram rendered as printed.
  final String? imgBase64;
}

final _diagramRe = RegExp(
  r'<chessdiagram\b([^>]*)>(.*?)</chessdiagram>',
  caseSensitive: false,
  dotAll: true,
);

final _fenAttrRe = RegExp(r'\bfen="([^"]*)"', caseSensitive: false);
final _annAttrRe = RegExp(r'\bann="([^"]*)"', caseSensitive: false);
final _dataPngRe = RegExp('data:image/[^;]+;base64,([^"\']+)');

/// Splits chapter HTML into prose segments and the diagrams embedded in it, so
/// each diagram can render as a native (reliably tappable) widget.
List<_Segment> _splitSegments(String html) {
  final segments = <_Segment>[];
  var cursor = 0;
  for (final m in _diagramRe.allMatches(html)) {
    if (m.start > cursor) {
      segments.add(_Segment.html(html.substring(cursor, m.start)));
    }
    final attrs = m.group(1) ?? '';
    final body = m.group(2) ?? '';
    final fen = _unescapeAttr(_fenAttrRe.firstMatch(attrs)?.group(1) ?? '');
    segments.add(_Segment.diagram(
      fen,
      ann: _unescapeAttr(_annAttrRe.firstMatch(attrs)?.group(1) ?? ''),
      imgBase64:
          fen.isEmpty ? _dataPngRe.firstMatch(body)?.group(1) : null,
    ));
    cursor = m.end;
  }
  if (cursor < html.length) {
    segments.add(_Segment.html(html.substring(cursor)));
  }
  if (segments.isEmpty) segments.add(_Segment.html(html));
  return segments;
}

String _unescapeAttr(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// Overlay color for recovered training arrows (lichess-style green).
const _arrowColor = Color(0xB315781B);

/// Stroke color for ✕-marked squares (the book's printed "x" crosses).
const _markColor = Color(0xB3C62828);

/// A detected diagram: a chessboard rendered from its FEN — with any recovered
/// training annotations (arrows, ✕ marks) drawn on top — the FEN caption, and
/// a tap target that loads the position onto the side board.
class _DiagramTile extends ConsumerWidget {
  const _DiagramTile({required this.fen, this.ann = ''});

  final String fen;

  /// Encoded training annotations; '' when the diagram has none.
  final String ann;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final annotations = decodeAnnotations(ann);
    // Cell index (row-major from a8) → dartchess Square (LERF, a1 = 0).
    Square squareOf(int cell) =>
        Square((cell % 8) | ((7 - cell ~/ 8) << 3));
    final arrows = <Shape>{
      for (final a in annotations)
        if (a.kind != BoardAnnotationKind.mark && a.from != a.to)
          Arrow(
            color: _arrowColor,
            orig: squareOf(a.from),
            dest: squareOf(a.to),
          ),
    };
    final marks = [
      for (final a in annotations)
        if (a.kind == BoardAnnotationKind.mark) a.from,
    ];
    final boardSettings = StaticChessboardSettings(
      pieceAssets: settings.pieceSet.assets,
      colorScheme: settings.boardColors,
      enableCoordinates: true,
    );

    void load() {
      final ok = ref.read(gameSessionProvider.notifier).loadFen(fen);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not read this diagram reliably')));
      }
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: const EdgeInsets.symmetric(vertical: 8),
          // Rendered as a real widget (not inside flutter_html), so an opaque
          // GestureDetector on the whole tile mirrors the PDF overlay's handler.
          // The explicit Load button below is the primary affordance.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: load,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The static board must not absorb the tap meant for the tile.
                IgnorePointer(
                  child: LayoutBuilder(
                    builder: (ctx, c) => Stack(
                      children: [
                        StaticChessboard(
                          size: c.maxWidth,
                          orientation: Side.white,
                          fen: fen,
                          settings: boardSettings,
                          shapes: arrows,
                        ),
                        // ✕ marks aren't a chessground shape, so they get
                        // their own paint layer over the board.
                        if (marks.isNotEmpty)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _XMarkPainter(marks),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          fen,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.tonalIcon(
                        onPressed: load,
                        icon: const Icon(Icons.login, size: 18),
                        label: const Text('Load'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a ✕ over each marked cell, mirroring the printed training crosses.
/// [marks] hold cell indexes in the pipeline's row-major-from-a8 order, which
/// with the tiles' fixed white orientation maps straight to screen cells.
class _XMarkPainter extends CustomPainter {
  const _XMarkPainter(this.marks);

  final List<int> marks;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 8;
    final paint = Paint()
      ..color = _markColor
      ..strokeWidth = (size.width / 90).clamp(2.0, 5.0)
      ..strokeCap = StrokeCap.round;
    final arm = cell * 0.55 / 2;
    for (final m in marks) {
      final cx = (m % 8 + 0.5) * cell;
      final cy = (m ~/ 8 + 0.5) * cell;
      canvas.drawLine(
          Offset(cx - arm, cy - arm), Offset(cx + arm, cy + arm), paint);
      canvas.drawLine(
          Offset(cx - arm, cy + arm), Offset(cx + arm, cy - arm), paint);
    }
  }

  @override
  bool shouldRepaint(_XMarkPainter old) => !listEquals(old.marks, marks);
}

/// A training diagram that couldn't be reconstructed reliably (e.g. the
/// letter-labelled flight-square pages): shown as printed, with no FEN or
/// Load affordance.
class _FallbackDiagramTile extends StatelessWidget {
  const _FallbackDiagramTile({required this.pngBase64});

  final String pngBase64;

  @override
  Widget build(BuildContext context) {
    final bytes = _decodeDataImage('data:image/png;base64,$pngBase64');
    if (bytes == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Image.memory(bytes, fit: BoxFit.contain),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text(
                  'Diagram (as printed)',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Decodes a `data:` image URI to bytes, skipping SVG (unsupported). Returns
/// null on malformed base64 — this runs during build on untrusted EPUB
/// content, so it must not throw.
Uint8List? _decodeDataImage(String src) {
  if (!src.startsWith('data:') || src.contains('svg')) return null;
  final comma = src.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64Decode(src.substring(comma + 1));
  } on FormatException {
    return null;
  }
}
