import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/persistence/library_store.dart';
import '../reader/state/book_providers.dart';
import 'book_cover.dart';
import 'open_book_button.dart';
import 'scan_book_button.dart';

/// Public-domain chess books on Project Gutenberg, offered as a starting
/// point instead of bundling EPUBs in the app: some storefronts (e.g. the
/// China mainland App Store) require a publishing permit for apps that ship
/// book content, which bundled samples would trigger.
const _kGutenbergLaskerUrl = 'https://www.gutenberg.org/ebooks/5614';
const _kGutenbergChessSearchUrl =
    'https://www.gutenberg.org/ebooks/search/?query=chess';

/// Shown when no book is open: a prominent "open" action plus a bookshelf grid
/// of recently-opened books (cover art extracted from each file) for one-tap
/// switching. Converted books reopen instantly from the cache.
class LibraryHome extends ConsumerWidget {
  const LibraryHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(libraryStoreProvider).recentPaths;
    final theme = Theme.of(context);

    if (recent.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.menu_book,
                  size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 16),
              const OpenBookButton(filled: true),
              const SizedBox(height: 8),
              const ScanBookButton(),
              TextButton.icon(
                icon: const Icon(Icons.auto_stories),
                label: const Text('Get a free chess book: Lasker\'s '
                    'Chess Strategy (Project Gutenberg)'),
                onPressed: () => launchUrl(
                  Uri.parse(_kGutenbergLaskerUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.search),
                label: const Text('Browse more chess books on Project '
                    'Gutenberg'),
                onPressed: () => launchUrl(
                  Uri.parse(_kGutenbergChessSearchUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const SizedBox(height: 8),
              const OpenBookButton(filled: true),
              const ScanBookButton(),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Recent books', style: theme.textTheme.titleSmall),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.builder(
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    childAspectRatio: 0.62,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: recent.length,
                  itemBuilder: (context, i) =>
                      _RecentCover(key: ValueKey(recent[i]), path: recent[i]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentCover extends ConsumerWidget {
  const _RecentCover({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exists = File(path).existsSync();
    final isEpub = path.toLowerCase().endsWith('.epub');
    return BookCoverTile(
      path: path,
      title: p.basenameWithoutExtension(path),
      isEpub: isEpub,
      enabled: exists,
      onTap: () => ref.read(openedBookProvider.notifier).open(path),
      trailing: CoverOverlayButton(
        icon: Icons.close,
        tooltip: 'Remove from list',
        onPressed: () =>
            ref.read(libraryStoreProvider.notifier).removeRecent(path),
      ),
    );
  }
}
