import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/persistence/library_store.dart';
import '../../../core/settings/app_settings.dart';
import '../../board/board_panel.dart';
import '../../library/about.dart';
import '../../library/converted_library_screen.dart';
import '../../library/library_home.dart';
import '../../library/open_book_button.dart';
import '../../settings/settings_screen.dart';
import '../data/book_conversion.dart';
import '../data/book_exporter.dart';
import '../data/epub_book.dart';
import '../data/pdf_html_builder.dart';
import '../state/book_providers.dart';
import '../state/conversion_provider.dart';
import 'epub_book_view.dart';
import 'move_strip.dart';
import 'pdf_book_view.dart';
import 'pdf_html_view.dart';
import 'reader_drawer.dart';

bool _isEpub(String path) => path.toLowerCase().endsWith('.epub');

/// Main screen: a library home until a book is opened, then the book pane and
/// board (side-by-side on wide layouts, a toggleable board panel on phones).
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  bool _boardVisibleNarrow = true;
  // One-shot per-book guards (sets, so switching between two books doesn't
  // re-fire a prompt already answered for either).
  final _promptedPaths = <String>{};
  final _noTextWarnedPaths = <String>{};
  final _ocrPromptedPaths = <String>{};

  /// Once the conversion is ready, either offer the reading-view choice (the
  /// PDF has usable text, whether from its own layer or recovered by OCR) or —
  /// if even OCR couldn't read this scan — warn and steer to Original pages.
  void _handleOpenedPdf(String path) {
    if (_isEpub(path)) return;
    // A freshly-opened scanned PDF (no cache yet) is gated: OCR is slow, so ask
    // whether to run it before the conversion proceeds. The conversion stays in
    // a loading state until the answer is recorded.
    final cached = ref.watch(conversionCachedProvider(path)).value ?? false;
    final imageOnly = ref.watch(pdfImageOnlyProvider(path)).value ?? false;
    if (!cached && imageOnly && ref.watch(ocrDecisionProvider(path)) == null) {
      _maybePromptOcr(path);
      return;
    }
    ref.watch(conversionProvider(path)).whenOrNull(data: (c) {
      if (c.hasExtractableText) {
        _maybePromptView(path);
      } else {
        _maybeWarnNoText(path);
      }
    });
  }

  /// A scanned/image-only PDF: ask once whether to convert it with on-device
  /// OCR (a reflowed Reading view, but slow) or keep the original pages. The
  /// answer unblocks [conversionProvider]; "Keep original" also pins the
  /// Original-pages view and suppresses the later no-text warning, while
  /// "Convert with OCR" pre-selects the Reading view.
  void _maybePromptOcr(String path) {
    if (!_ocrPromptedPaths.add(path)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final runOcr = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Scanned PDF'),
          content: const Text(
            'This book is a scanned PDF — its pages are images with no text '
            'layer.\n\n'
            'It can be converted with on-device text recognition (OCR) so you '
            'get a reflowed Reading view with searchable text and tappable '
            'moves. OCR runs entirely on your device and can take several '
            'minutes for a long book.\n\n'
            'You can keep the original pages instead — diagrams are still '
            'detected and playable either way.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep original'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Convert with OCR'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      final decision = runOcr ?? false; // dismissed → keep original
      final library = ref.read(libraryStoreProvider.notifier);
      if (decision) {
        // They asked for the reading view; don't also ask which view to use.
        library.setViewMode(path, kViewModeHtml);
        _promptedPaths.add(path);
      } else {
        library.setViewMode(path, kViewModePdf);
        _promptedPaths.add(path);
        _noTextWarnedPaths.add(path); // no OCR → no text; don't nag about it
      }
      ref.read(ocrDecisionProvider(path).notifier).decide(decision);
    });
  }

  /// Whether to offer the "Run OCR" action: a scanned PDF that was converted
  /// without OCR (opened with "Keep original"), so no text was recovered yet.
  bool _canRunOcr(String path) {
    if (_isEpub(path)) return false;
    final c = ref.watch(conversionProvider(path)).value;
    return c != null &&
        c.format == 'pdf' &&
        !c.hasExtractableText &&
        !c.ocrAttempted;
  }

  /// Re-runs the conversion with OCR enabled for a scanned PDF that was opened
  /// with "Keep original". Drops the no-OCR cache, switches to the Reading view,
  /// and clears the one-shot prompt guards so that — if OCR still can't read the
  /// scan — the no-text warning fires again and steers back to Original pages.
  Future<void> _runOcrNow(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run OCR now?'),
        content: const Text(
          'Text recognition runs on your device and can take several minutes '
          'for a long book. When it finishes, the Reading view with searchable '
          'text and tappable moves becomes available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Run OCR'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await deleteCachedConversion(path);
    _noTextWarnedPaths.remove(path); // let the warning re-fire if OCR fails
    _promptedPaths.add(path); // they've chosen the Reading view; don't re-ask
    ref.read(ocrDecisionProvider(path).notifier).decide(true);
    ref.read(libraryStoreProvider.notifier).setViewMode(path, kViewModeHtml);
    ref.read(partialConversionProvider.notifier).clear(path);
    ref.invalidate(conversionCachedProvider(path));
    ref.invalidate(conversionProvider(path));
  }

  /// A scanned PDF that even on-device OCR couldn't read (poor/low-res scan):
  /// clickable moves and the reading view can't work. Warn once, force Original
  /// pages, and suppress the reading-view prompt.
  void _maybeWarnNoText(String path) {
    if (!_noTextWarnedPaths.add(path)) return;
    _promptedPaths.add(path); // don't also ask which view to use
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      ref.read(libraryStoreProvider.notifier).setViewMode(path, kViewModePdf);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Scanned PDF — diagrams still work'),
          content: const Text(
            'This PDF is scanned page images. Automatic text recognition (OCR) '
            'ran during conversion but couldn\'t recover enough reliable text '
            'from this scan, so the reflowed Reading view and tapping moves in '
            'the text aren\'t available.\n\n'
            'The original pages still display normally, and diagram detection '
            'reads the printed positions onto the board — just tap a diagram to '
            'play through it.\n\n'
            'A cleaner, higher-resolution scan usually recognizes better.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });
  }

  /// On opening a PDF with no saved preference, ask how to read it.
  void _maybePromptView(String path) {
    if (_isEpub(path) || _promptedPaths.contains(path)) return;
    if (ref.read(libraryStoreProvider).viewMode[path] != null) return;
    _promptedPaths.add(path);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final mode = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('How would you like to read this PDF?'),
          content: const Text(
            'Original pages keep the book exactly as printed.\n\n'
            'Reading view reflows the text so it is easier on small screens; '
            'layout and fonts are approximate.\n\n'
            'You can switch anytime from the toolbar.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(kViewModePdf),
              child: const Text('Original pages'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(kViewModeHtml),
              child: const Text('Reading view'),
            ),
          ],
        ),
      );
      ref
          .read(libraryStoreProvider.notifier)
          .setViewMode(path, mode ?? kViewModePdf);
    });
  }

  Future<void> _exportConverted(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    // Captured before any await for the iPad share popover anchor (and to keep
    // the async gap clear of BuildContext use).
    final shareOrigin = _shareOrigin();
    messenger.showSnackBar(
        const SnackBar(content: Text('Preparing export…')));
    try {
      final conversion = await ref.read(conversionProvider(path).future);
      final chapters = _isEpub(path)
          ? (await loadEpubBook(path, diagrams: conversion)).chapters
          : buildPdfChapters(conversion);
      final title = p.basenameWithoutExtension(path);
      final html = buildExportHtml(title, chapters);
      final fileName = '$title.html';

      if (Platform.isIOS || Platform.isAndroid) {
        // Mobile has no "save file" dialog, so file_selector's getSaveLocation
        // can't return a writable path (it fails with a "set path" error).
        // Instead write to a temp file and hand it to the system share sheet,
        // letting the user save it to Files/iCloud or send it onward.
        final file = File(p.join((await getTemporaryDirectory()).path, fileName));
        await file.writeAsString(html);
        await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path, mimeType: 'text/html')],
          subject: title,
          sharePositionOrigin: shareOrigin,
        ));
        return;
      }

      final location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'HTML', extensions: ['html']),
        ],
      );
      if (location == null) return;
      await File(location.path).writeAsString(html);
      messenger.showSnackBar(
          SnackBar(content: Text('Exported to ${location.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  /// Anchor rect for the iPad share popover; null on other targets (where the
  /// share sheet is a full-screen modal that ignores it).
  Rect? _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final bookPath = ref.watch(openedBookProvider);
    if (bookPath != null) _handleOpenedPdf(bookPath);
    final showViewToggle = bookPath != null && !_isEpub(bookPath);
    final canRunOcr = bookPath != null && _canRunOcr(bookPath);

    return Scaffold(
      endDrawer: bookPath != null ? ReaderDrawer(path: bookPath) : null,
      appBar: AppBar(
        title: const Text('ChessBook Reader'),
        actions: [
          if (canRunOcr)
            TextButton.icon(
              onPressed: () => _runOcrNow(bookPath),
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Run OCR'),
            ),
          if (showViewToggle) _ViewToggle(path: bookPath),
          OpenBookButton(tooltip: bookPath == null ? null : 'Open another book'),
          if (bookPath != null)
            IconButton(
              tooltip: 'Close book',
              icon: const Icon(Icons.close),
              onPressed: () =>
                  ref.read(openedBookProvider.notifier).close(),
            ),
          if (bookPath != null)
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Contents, search, bookmarks',
                icon: const Icon(Icons.menu_open),
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'export':
                  if (bookPath != null) _exportConverted(bookPath);
                case 'library':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ConvertedLibraryScreen()));
                case 'settings':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SettingsScreen()));
                case 'about':
                  showAppAboutDialog(context);
              }
            },
            itemBuilder: (context) => [
              if (bookPath != null)
                const PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    leading: Icon(Icons.download),
                    title: Text('Export converted HTML…'),
                  ),
                ),
              const PopupMenuItem(
                value: 'library',
                child: ListTile(
                  leading: Icon(Icons.library_books),
                  title: Text('Converted books'),
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('Settings'),
                ),
              ),
              const PopupMenuItem(
                value: 'about',
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('About'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bookPane = _BookPane(path: bookPath);

          // No book open: full-width library home (no board chrome).
          if (bookPath == null) return bookPane;

          final boardPane = Column(
            children: const [
              Expanded(child: BoardPanel()),
              MoveStrip(),
            ],
          );

          final placement =
              ref.watch(settingsProvider.select((s) => s.boardPlacement));

          // Auto: side-by-side on wide screens, collapsible bottom panel on
          // phones. Explicit placements force their arrangement everywhere.
          if (placement == BoardPlacement.auto) {
            return constraints.maxWidth >= 900
                ? _split(constraints, BoardPlacement.right, bookPane, boardPane)
                : _narrowCollapsible(constraints, bookPane, boardPane);
          }
          return _split(constraints, placement, bookPane, boardPane);
        },
      ),
    );
  }

  /// A resizable two-pane split with the board on the [placement] side.
  Widget _split(BoxConstraints constraints, BoardPlacement placement,
      Widget bookPane, Widget boardPane) {
    final horizontal =
        placement == BoardPlacement.left || placement == BoardPlacement.right;
    final boardFirst =
        placement == BoardPlacement.left || placement == BoardPlacement.top;
    final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
    const handle = 10.0;
    final fraction = ref.watch(settingsProvider.select((s) => s.boardFraction));
    final boardExtent = (total - handle) * fraction;
    final bookExtent = total - handle - boardExtent;

    final board = SizedBox(
      width: horizontal ? boardExtent : null,
      height: horizontal ? null : boardExtent,
      child: Padding(padding: const EdgeInsets.all(12), child: boardPane),
    );
    final book = SizedBox(
      width: horizontal ? bookExtent : null,
      height: horizontal ? null : bookExtent,
      child: bookPane,
    );
    final divider = _ResizeHandle(
      axis: horizontal ? Axis.horizontal : Axis.vertical,
      // Dragging the handle towards the book pane grows the board.
      onDelta: (d) => ref
          .read(settingsProvider.notifier)
          .setBoardFraction(fraction + (boardFirst ? d : -d) / total),
    );

    final children =
        boardFirst ? [board, divider, book] : [book, divider, board];
    return horizontal
        ? Row(children: children)
        : Column(children: children);
  }

  /// Phone default: book fills the screen with a toggleable bottom board panel.
  /// When expanded the board is drag-resizable (same `boardFraction` setting and
  /// `_ResizeHandle` as the explicit side/top/bottom splits); the chevron still
  /// collapses it away entirely.
  Widget _narrowCollapsible(
      BoxConstraints constraints, Widget bookPane, Widget boardPane) {
    final fraction = ref.watch(settingsProvider.select((s) => s.boardFraction));
    final total = constraints.maxHeight;
    return Column(
      children: [
        Expanded(child: bookPane),
        Material(
          elevation: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => setState(
                    () => _boardVisibleNarrow = !_boardVisibleNarrow),
                child: SizedBox(
                  height: 32,
                  child: Icon(_boardVisibleNarrow
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up),
                ),
              ),
              if (_boardVisibleNarrow) ...[
                _ResizeHandle(
                  axis: Axis.vertical,
                  // The board is the bottom pane: dragging the handle up grows it.
                  onDelta: (d) => ref
                      .read(settingsProvider.notifier)
                      .setBoardFraction(fraction - d / total),
                ),
                SizedBox(
                  height: total * fraction,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: boardPane,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Original-pages / reading-view switch (PDF only).
class _ViewToggle extends ConsumerWidget {
  const _ViewToggle({required this.path});
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(libraryStoreProvider).viewMode[path] ?? kViewModePdf;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
              value: kViewModePdf,
              icon: Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Original pages'),
          ButtonSegment(
              value: kViewModeHtml,
              icon: Icon(Icons.article_outlined),
              tooltip: 'Reading view'),
        ],
        selected: {mode},
        onSelectionChanged: (s) =>
            ref.read(libraryStoreProvider.notifier).setViewMode(path, s.first),
      ),
    );
  }
}

/// Draggable divider between the book pane and the board. [axis] is the axis
/// the two panes are arranged along: horizontal for a Row (drag left/right),
/// vertical for a Column (drag up/down).
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.axis, required this.onDelta});
  final Axis axis;
  final void Function(double delta) onDelta;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    final bar = Container(
      width: horizontal ? 4 : 32,
      height: horizontal ? 32 : 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate:
            horizontal ? (d) => onDelta(d.delta.dx) : null,
        onVerticalDragUpdate:
            horizontal ? null : (d) => onDelta(d.delta.dy),
        child: SizedBox(
          width: horizontal ? 10 : double.infinity,
          height: horizontal ? double.infinity : 10,
          child: Center(child: bar),
        ),
      ),
    );
  }
}

class _BookPane extends ConsumerWidget {
  const _BookPane({required this.path});
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (path == null) return const LibraryHome();
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(12),
      child: _book(context, ref, path!),
    );
  }

  Widget _book(BuildContext context, WidgetRef ref, String path) {
    // Diagram detection runs up front, but the reader opens as soon as
    // ~20% is converted (kReadableThreshold); the rest converts in the
    // background and diagrams appear as their page completes. Watch the full
    // conversion to start it and surface errors; gate display on the effective
    // (partial-or-full) conversion.
    final full = ref.watch(conversionProvider(path));
    if (full.hasError) {
      return Center(child: Text('Could not open book: ${full.error}'));
    }
    final c = ref.watch(effectiveConversionProvider(path));
    // Open once the book is fully converted, OR the user tapped "Start reading"
    // after ~20% is ready. Until then show the progress screen (with the button
    // offered as soon as enough is converted).
    final startedEarly = ref.watch(readEarlyProvider).contains(path);
    final ready = full.value != null || (c != null && startedEarly);
    if (!ready) {
      return _progress(context, ref, path, canStart: c != null);
    }

    final Widget view;
    if (_isEpub(path)) {
      view = EpubBookView(path: path);
    } else {
      final mode =
          ref.watch(libraryStoreProvider).viewMode[path] ?? kViewModePdf;
      view = mode == kViewModeHtml
          ? PdfHtmlView(path: path, conversion: c!)
          : PdfBookView(path: path);
    }

    final progress =
        (ref.watch(conversionProgressProvider)[path] ?? 1).clamp(0.0, 1.0);
    if (progress >= 1) return view;
    return Stack(
      children: [
        view,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _BackgroundConversionBar(progress: progress),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context, WidgetRef ref, String path,
      {bool canStart = false}) {
    final fraction =
        (ref.watch(conversionProgressProvider)[path] ?? 0).clamp(0.0, 1.0);
    final pct = (fraction * 100).toStringAsFixed(0);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(
                value: fraction == 0 ? null : fraction),
          ),
          const SizedBox(height: 12),
          Text('Detecting chess diagrams… $pct%'),
          // Once enough of the book is converted, let the reader start now and
          // finish the rest in the background.
          if (canStart) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(readEarlyProvider.notifier).start(path),
              icon: const Icon(Icons.menu_book),
              label: const Text('Start reading'),
            ),
            const SizedBox(height: 4),
            Text(
              'The rest keeps converting in the background.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          // Closing the book drops the conversion provider's last listener,
          // which aborts the running conversion (nothing is cached).
          TextButton(
            onPressed: () => ref.read(openedBookProvider.notifier).close(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Slim, non-interactive banner shown at the top of the reader while the
/// remaining pages convert in the background (the book opened at ~20%).
class _BackgroundConversionBar extends StatelessWidget {
  const _BackgroundConversionBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            minHeight: 3,
            value: progress == 0 ? null : progress,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.all(6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Converting diagrams… ${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 11, color: scheme.onSecondaryContainer),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
