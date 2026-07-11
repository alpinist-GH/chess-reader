import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Imports a just-picked book into app-managed storage and returns the path to
/// use from then on.
///
/// On iOS/Android the path the file picker hands back is a *temporary* copy
/// (the OS purges it) and, for an iCloud file, may still be an unmaterialised
/// placeholder when first opened — which makes PDFium fail with
/// `FPDF_ERR_FILE` on the first load and the recent-books entry stop opening
/// days later. macOS hits the same `FPDF_ERR_FILE` failure for a different
/// reason: the app is sandboxed, and the access NSOpenPanel grants to a
/// user-picked file outside the container is only good for the current
/// process — the plain path we persist for "recent books" no longer resolves
/// after a relaunch (the alternative, security-scoped bookmarks, needs native
/// code we don't have; copying sidesteps the problem entirely). To avoid all
/// of this, we copy the file once into Application Support (a stable,
/// app-private directory) and use that copy everywhere. The copy is
/// deduplicated by name + size, so re-picking the same book reuses it and keeps
/// the conversion-cache, cover and recent-list keys stable.
///
/// On Windows/Linux the picker already returns a durable path, so it is used
/// as-is.
Future<String> importBook(String sourcePath) async {
  if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) {
    return sourcePath;
  }
  try {
    final booksDir = await _booksDir();
    // A recent-book reopen already points at our copy — nothing to do.
    if (p.isWithin(booksDir.path, sourcePath)) return sourcePath;

    final src = File(sourcePath);
    final size = await src.length();
    final name = p.basename(sourcePath);
    // Keep the original filename as the leaf (so titles derived from it stay
    // clean) and disambiguate by size in the parent folder.
    final key = '${p.basenameWithoutExtension(name)}_$size';
    final dest = File(p.join(booksDir.path, key, name));
    if (await dest.exists() && await dest.length() == size) {
      return dest.path; // Already imported.
    }
    await dest.parent.create(recursive: true);
    await src.copy(dest.path);
    return dest.path;
  } catch (_) {
    // If importing fails for any reason, fall back to the original path so the
    // open still has a chance to succeed.
    return sourcePath;
  }
}

Future<Directory> _booksDir() async {
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'books'));
}
