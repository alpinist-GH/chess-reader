import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Public-domain chess books on Project Gutenberg and the Internet Archive,
/// offered as a starting point instead of bundling EPUBs in the app: some
/// storefronts (e.g. the China mainland App Store) require a publishing
/// permit for apps that ship book content, which bundled samples would
/// trigger.
const _kGutenbergLaskerUrl = 'https://www.gutenberg.org/ebooks/5614';
const _kArchiveOrgChessUrl = 'https://archive.org/details/folkscanomy_chess';

/// Shared discovery links, available both at home and while reading.
class BookSuggestions extends StatelessWidget {
  const BookSuggestions({super.key});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        icon: const Icon(Icons.auto_stories),
        label: const Text(
          'Get a free chess book: Lasker\'s '
          'Chess Strategy (Project Gutenberg)',
        ),
        onPressed: () => launchUrl(
          Uri.parse(_kGutenbergLaskerUrl),
          mode: LaunchMode.externalApplication,
        ),
      ),
      TextButton.icon(
        icon: const Icon(Icons.search),
        label: const Text(
          'Browse more chess books on the '
          'Internet Archive',
        ),
        onPressed: () => launchUrl(
          Uri.parse(_kArchiveOrgChessUrl),
          mode: LaunchMode.externalApplication,
        ),
      ),
    ],
  );
}

Future<void> showBookSuggestions(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Find chess books'),
    content: const SingleChildScrollView(child: BookSuggestions()),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  ),
);
