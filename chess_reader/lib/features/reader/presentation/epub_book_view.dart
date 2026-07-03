import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/epub_book.dart';
import '../state/conversion_provider.dart';
import 'book_html_view.dart';

/// Parsed EPUB, keyed by file path. Depends on the conversion pass so detected
/// diagrams are wrapped as `<chessdiagram>`; the reader already awaits the
/// conversion, so this resolves promptly.
final epubBookProvider =
    FutureProvider.autoDispose.family<EpubBook, String>((ref, path) async {
  final conversion = await ref.watch(conversionProvider(path).future);
  final book = await loadEpubBook(path, diagrams: conversion);
  // Cache the parsed book (and, via the watch above, the conversion) for the
  // rest of the session once it has loaded successfully.
  ref.keepAlive();
  return book;
});

/// EPUB reader: chapters as a scrollable list of HTML with tappable
/// `<chessmove>` spans and `<chessdiagram>` tiles.
class EpubBookView extends ConsumerWidget {
  const EpubBookView({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(epubBookProvider(path));
    return book.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not open EPUB: $e')),
      data: (book) => HtmlChapterList(
        path: path,
        chapters: book.chapters,
        sourceKeyPrefix: 'ch',
      ),
    );
  }
}
