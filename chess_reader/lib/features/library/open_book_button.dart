import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/state/book_providers.dart';
import '../reader/data/processed_book.dart';
import '../reader/state/conversion_provider.dart';
import '../reader/state/diagram_corrections_provider.dart';

class OpenBookButton extends ConsumerWidget {
  const OpenBookButton({super.key, this.filled = false, this.tooltip});

  /// Render as a prominent filled button (empty state) instead of an icon.
  final bool filled;

  /// Tooltip for the icon variant; defaults to 'Open book'.
  final String? tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> pick() async {
      const typeGroup = XTypeGroup(
        label: 'Chess books',
        extensions: ['pdf', 'epub'],
        // On iOS/macOS type groups are matched by UTI.
        uniformTypeIdentifiers: ['com.adobe.pdf', 'org.idpf.epub-container'],
      );
      final file = await openFile(
        acceptedTypeGroups: const [
          typeGroup,
          XTypeGroup(
            label: 'Processed chess book',
            extensions: ['zip'],
            uniformTypeIdentifiers: ['public.zip-archive'],
          ),
        ],
      );
      if (file != null) {
        try {
          final isProcessed = file.path.toLowerCase().endsWith('.zip');
          final path = isProcessed
              ? await importProcessedBook(file.path)
              : file.path;
          if (isProcessed) {
            // The import can replace a conversion already held for this path.
            ref.invalidate(conversionCachedProvider(path));
            ref.invalidate(conversionProvider(path));
            // ...and the bundle's corrections were just merged into the file.
            ref.invalidate(diagramCorrectionsProvider(path));
          }
          await ref.read(openedBookProvider.notifier).open(path);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
          }
        }
      }
    }

    if (filled) {
      return FilledButton.icon(
        onPressed: pick,
        icon: const Icon(Icons.folder_open),
        label: const Text('Open / import book (PDF, EPUB or processed ZIP)'),
      );
    }
    return IconButton(
      tooltip: tooltip ?? 'Open / import book',
      icon: const Icon(Icons.folder_open),
      onPressed: pick,
    );
  }
}
