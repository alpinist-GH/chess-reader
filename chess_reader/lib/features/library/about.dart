import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// App version shown in the About box. Keep in sync with pubspec `version`.
const String kAppVersion = '1.2.0';

/// Where users can obtain the corresponding source code. Bundling Stockfish
/// (GPL v3) obliges us to offer its source; we link both upstream Stockfish
/// and this app (also GPL v3, so the same applies to it).
const String _kStockfishSourceUrl = 'https://github.com/official-stockfish/Stockfish';
const String _kAppSourceUrl = 'https://github.com/alpinist-GH/chess-reader';

/// Registers Stockfish's copyright + GPL v3 notice so it always shows under the
/// About box's "View licenses" page, independent of how the bundled engine
/// package declares its license. Call once at startup.
void registerStockfishLicense() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['Stockfish'],
      'ChessBook Reader bundles the Stockfish chess engine, run in-process via '
      'Dart FFI.\n\n'
      'Stockfish is free software: you can redistribute it and/or modify it '
      'under the terms of the GNU General Public License as published by the '
      'Free Software Foundation, either version 3 of the License, or (at your '
      'option) any later version.\n\n'
      'Stockfish is distributed in the hope that it will be useful, but '
      'WITHOUT ANY WARRANTY; without even the implied warranty of '
      'MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU '
      'General Public License for more details.\n\n'
      'The corresponding source code for Stockfish is available at '
      '$_kStockfishSourceUrl\n\n'
      'Copyright (C) 2004-2024 The Stockfish developers '
      '(see AUTHORS file in the Stockfish source).',
    );
  });
}

/// Shows the About dialog: what the app does, its license, and author.
/// The dialog's built-in "View licenses" button lists all bundled
/// open-source license texts, including Stockfish's full GPL v3.
void showAppAboutDialog(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'ChessBook Reader',
    applicationVersion: kAppVersion,
    applicationIcon: const Icon(Icons.menu_book, size: 40),
    applicationLegalese:
        'Made by Vu-Hung Quan\nLicensed under the GNU GPL v3.0',
    children: [
      const SizedBox(height: 12),
      const Text(
        'An offline interactive chess book reader.\n\n'
        '• Opens PDF and EPUB chess books.\n'
        '• Click any move in the text to follow it on the board.\n'
        '• Analyse any position with the built-in Stockfish engine.\n'
        '• Automatically detects printed diagrams and reads them into '
        'positions you can load with one tap.\n'
        '• Converts books to a reflowed reading view and can export them as '
        'standalone HTML.\n\n'
        'Everything runs locally — no internet connection or server is '
        'required.',
      ),
      const SizedBox(height: 12),
      const Text(
        'This program is free software, distributed under the GNU General '
        'Public License v3.0.\n\n'
        'It bundles the Stockfish chess engine (Copyright © The Stockfish '
        'developers), compiled and linked into the app and run in-process via '
        'Dart FFI. Stockfish is licensed under the GNU GPL v3, as is this '
        'app. The full license texts are available under "View licenses" '
        'below; the corresponding source code is linked here:',
      ),
      const SizedBox(height: 8),
      _SourceLink(
        label: 'Stockfish source code',
        url: _kStockfishSourceUrl,
      ),
      _SourceLink(
        label: 'ChessBook Reader source code',
        url: _kAppSourceUrl,
      ),
    ],
  );
}

/// A tappable link that opens [url] in the system browser.
class _SourceLink extends StatelessWidget {
  const _SourceLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text(label),
        onPressed: () => launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        ),
      ),
    );
  }
}
