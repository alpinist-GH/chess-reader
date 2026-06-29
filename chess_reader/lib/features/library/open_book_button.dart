import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader/state/book_providers.dart';

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
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file != null) {
        ref.read(openedBookProvider.notifier).open(file.path);
      }
    }

    if (filled) {
      return FilledButton.icon(
        onPressed: pick,
        icon: const Icon(Icons.folder_open),
        label: const Text('Open a chess book (PDF or EPUB)'),
      );
    }
    return IconButton(
      tooltip: tooltip ?? 'Open book',
      icon: const Icon(Icons.folder_open),
      onPressed: pick,
    );
  }
}
