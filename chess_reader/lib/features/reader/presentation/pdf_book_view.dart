import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/persistence/library_store.dart';
import '../../../core/state/game_session.dart';
import '../data/book_conversion.dart';
import '../data/page_moves_service.dart';
import '../state/book_providers.dart';
import '../state/conversion_provider.dart';
import '../state/reader_nav.dart';

/// PDF viewer with clickable chess moves overlaid on each page. Attaches its
/// controller to [pdfControllerProvider], resumes at the last-read page, and
/// records page changes for resume + bookmark labelling.
class PdfBookView extends ConsumerStatefulWidget {
  const PdfBookView({super.key, required this.path});

  final String path;

  @override
  ConsumerState<PdfBookView> createState() => _PdfBookViewState();
}

class _PdfBookViewState extends ConsumerState<PdfBookView> {
  final _controller = PdfViewerController();

  @override
  void dispose() {
    ref.read(pdfControllerProvider.notifier).detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resumePage =
        ref.read(libraryStoreProvider.notifier).lastPageFor(widget.path) ?? 1;
    return PdfViewer.file(
      widget.path,
      controller: _controller,
      initialPageNumber: resumePage,
      params: PdfViewerParams(
        onViewerReady: (document, controller) {
          ref.read(pdfControllerProvider.notifier).attach(_controller);
        },
        onPageChanged: (pageNumber) {
          if (pageNumber == null) return;
          ref.read(currentPageProvider.notifier).set(pageNumber);
          ref.read(libraryStoreProvider.notifier)
              .recordPage(widget.path, pageNumber);
        },
        pageOverlaysBuilder: (context, pageRect, page) => [
          _PageMovesOverlay(page: page, pageSize: pageRect.size),
          _DiagramAnchorsOverlay(
              page: page, pageSize: pageRect.size, path: widget.path),
        ],
        // Persistent, draggable page scrollbar on the right edge: shows the
        // current page and lets you scrub through the book (the original/PDF
        // view otherwise has no position indicator, unlike the reflowed view).
        viewerOverlayBuilder: (context, size, handleLinkTap) => [
          PdfViewerScrollThumb(
            controller: _controller,
            orientation: ScrollbarOrientation.right,
            thumbSize: const Size(44, 36),
            thumbBuilder: (context, thumbSize, pageNumber, controller) {
              final scheme = Theme.of(context).colorScheme;
              return Material(
                color: scheme.primary,
                elevation: 2,
                borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(10)),
                child: SizedBox(
                  width: thumbSize.width,
                  height: thumbSize.height,
                  child: Center(
                    child: Text(
                      '${pageNumber ?? ''}',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Tap targets for the resolved moves of one page. Children are positioned
/// relative to the page (the viewer wraps overlays in a page-sized Stack).
class _PageMovesOverlay extends ConsumerWidget {
  const _PageMovesOverlay({required this.page, required this.pageSize});

  final PdfPage page;
  final Size pageSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movesFuture = ref.watch(pageMovesServiceProvider).movesForPage(page);
    final active = ref.watch(activeLineProvider);
    final highlight = Theme.of(context).colorScheme.primary;

    return FutureBuilder<PageMovesResult>(
      future: movesFuture,
      builder: (context, snapshot) {
        final result = snapshot.data;
        if (result == null || result.moves.isEmpty) {
          return const SizedBox.shrink();
        }
        final isActivePage =
            active != null && active.sourceKey == result.pageNumber;
        return Stack(
          children: [
            for (var i = 0; i < result.moves.length; i++)
              _moveTarget(
                context,
                ref,
                result,
                i,
                selected: isActivePage && active.index == i,
                highlight: highlight,
              ),
          ],
        );
      },
    );
  }

  Widget _moveTarget(
    BuildContext context,
    WidgetRef ref,
    PageMovesResult result,
    int index, {
    required bool selected,
    required Color highlight,
  }) {
    final move = result.moves[index];
    final rect = move.bounds.toRect(page: page, scaledPageSize: pageSize);
    // Slight padding so the highlight does not hug the glyphs.
    final padded = rect.inflate(1.5);
    return Positioned(
      left: padded.left,
      top: padded.top,
      width: padded.width,
      height: padded.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(activeLineProvider.notifier).select(
            [for (final m in result.moves) m.resolved],
            index,
            result.pageNumber),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: highlight.withValues(alpha: selected ? 0.28 : 0.10),
            borderRadius: BorderRadius.circular(3),
            border: selected ? Border.all(color: highlight, width: 1) : null,
          ),
        ),
      ),
    );
  }
}

/// Auto-detected diagrams for one page (from the up-front conversion). Each
/// recognized board becomes a tappable hotspot that loads its position onto
/// the side board — no scan button.
class _DiagramAnchorsOverlay extends ConsumerWidget {
  const _DiagramAnchorsOverlay({
    required this.page,
    required this.pageSize,
    required this.path,
  });

  final PdfPage page;
  final Size pageSize;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read the incremental conversion so diagrams appear as their page finishes
    // converting in the background (not only when the whole book is done).
    final conversion = ref.watch(effectiveConversionProvider(path));
    final diagrams =
        conversion?.diagramsFor(page.pageNumber) ?? const <ConvertedDiagram>[];
    if (diagrams.isEmpty) return const SizedBox.shrink();

    // Raster pixels (200 dpi) → page-widget coordinates.
    final toWidget = pageSize.width / (page.width * 200 / 72);
    final highlight = Theme.of(context).colorScheme.primary;

    return Stack(
      children: [
        for (final d in diagrams)
          Positioned(
            left: d.left * toWidget,
            top: d.top * toWidget,
            width: d.size * toWidget,
            height: d.size * toWidget,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final ok =
                    ref.read(gameSessionProvider.notifier).loadFen(d.fen);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content:
                          Text('Could not read this diagram reliably')));
                }
              },
              // Just a subtle border (no corner badge) marks the tappable
              // diagram; the tooltip explains it on hover.
              child: Tooltip(
                message: 'Tap to load this position',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: highlight.withValues(alpha: 0.6), width: 2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
