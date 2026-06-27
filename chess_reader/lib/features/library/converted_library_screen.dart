import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/data/book_conversion.dart';
import '../reader/state/book_providers.dart';
import 'book_cover.dart';

/// A standalone screen listing every book that has been converted (cached on
/// disk). Each opens instantly; the cache entry can be deleted.
class ConvertedLibraryScreen extends ConsumerStatefulWidget {
  const ConvertedLibraryScreen({super.key});

  @override
  ConsumerState<ConvertedLibraryScreen> createState() =>
      _ConvertedLibraryScreenState();
}

class _ConvertedLibraryScreenState
    extends ConsumerState<ConvertedLibraryScreen> {
  late Future<List<CachedBook>> _future = listCachedConversions();

  void _refresh() => setState(() => _future = listCachedConversions());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Converted books')),
      body: FutureBuilder<List<CachedBook>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final books = snap.data!;
          if (books.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No converted books yet.\n'
                  'Open a PDF or EPUB and it will be converted and saved here.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: books.length,
            itemBuilder: (context, i) {
              final book = books[i];
              final exists = File(book.path).existsSync();
              return BookCoverTile(
                key: ValueKey(book.path),
                path: book.path,
                title: book.title,
                isEpub: book.format == 'epub',
                enabled: exists,
                onTap: () {
                  ref.read(openedBookProvider.notifier).open(book.path);
                  Navigator.of(context).pop();
                },
                trailing: CoverOverlayButton(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete saved conversion',
                  onPressed: () async {
                    await deleteCachedConversion(book.path);
                    _refresh();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
