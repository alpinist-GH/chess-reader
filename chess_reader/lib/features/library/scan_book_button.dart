import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../reader/state/book_providers.dart';
import 'scan_to_pdf.dart';

/// Lets the user photograph the pages of a printed chess book with the device's
/// document scanner, assembles them into a PDF, and opens it through the normal
/// pipeline (which then runs OCR automatically, since a scan has no text layer).
///
/// Mobile only — renders nothing on desktop, where there is no camera-scan UX.
class ScanBookButton extends ConsumerStatefulWidget {
  const ScanBookButton({super.key});

  @override
  ConsumerState<ScanBookButton> createState() => _ScanBookButtonState();
}

class _ScanBookButtonState extends ConsumerState<ScanBookButton> {
  bool _busy = false;

  Future<void> _scan() async {
    setState(() => _busy = true);
    try {
      // The native scanner throws an opaque "permission not granted" error if
      // the camera was denied, with no way to recover, so we drive the
      // permission flow ourselves: request once, and if the user has
      // permanently denied it, offer to open the OS settings.
      if (!await _ensureCameraPermission()) return;

      // Opens the native scanner (iOS VisionKit / Android ML Kit), which also
      // triggers the OS camera-permission prompt on first use. Returns the
      // captured, cropped page-image paths, or null/empty if the user cancels.
      final images = await CunningDocumentScanner.getPictures();
      if (images == null || images.isEmpty) return;

      final pdfPath = await buildPdfFromImages(images);
      // open() imports the PDF into stable app storage and records it in the
      // recent library, exactly like a picked file.
      await ref.read(openedBookProvider.notifier).open(pdfPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not scan pages: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns true once the camera is usable. Requests the permission on first
  /// use; if the user has permanently denied (or restricted) it, prompts them
  /// to open the OS settings, since iOS/Android will not re-show the system
  /// dialog after the first denial.
  Future<bool> _ensureCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted || status.isLimited) return true;

    if (status.isDenied) {
      status = await Permission.camera.request();
      if (status.isGranted || status.isLimited) return true;
    }

    if (mounted && (status.isPermanentlyDenied || status.isRestricted)) {
      await _showOpenSettingsDialog();
    }
    return false;
  }

  Future<void> _showOpenSettingsDialog() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Camera access needed'),
        content: const Text(
          'To scan the pages of a printed book, allow camera access for '
          'ChessBook Reader in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (open ?? false) await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    if (!(Platform.isIOS || Platform.isAndroid)) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.document_scanner),
      label: const Text('Scan a paper book'),
      onPressed: _busy ? null : _scan,
    );
  }
}
