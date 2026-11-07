import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/book_conversion.dart';
import '../data/diagram_corrections.dart';
import 'conversion_provider.dart';

/// The user's hand-corrected diagram positions for one book, by [diagramKey].
/// Loaded from disk once, then written through on every change.
class DiagramCorrections extends Notifier<Map<String, String>> {
  DiagramCorrections(this.path);

  final String path;

  /// Completes when the saved corrections have been read. Reassigned by every
  /// [build] (an invalidate re-runs it on the same instance), so it must not be
  /// `late final`. Every mutation awaits it: an edit made before the load
  /// finished would otherwise be written without the corrections already saved.
  Future<void> loaded = Future.value();

  /// Tail of the write queue. Writes are strictly ordered, each carrying the
  /// full map as of its mutation, so the file always ends up matching [state].
  Future<void> _writes = Future.value();

  @override
  Map<String, String> build() {
    loaded = _load();
    return const {};
  }

  Future<void> _load() async {
    final saved = await loadDiagramCorrections(path);
    if (saved.isNotEmpty) state = saved;
  }

  Future<void> _mutate(
    Map<String, String> Function(Map<String, String> current) change,
  ) async {
    await loaded;
    state = change(state);
    final snapshot = state;
    final write = _writes.then((_) => saveDiagramCorrections(path, snapshot));
    // A failed write must not wedge the queue; the caller still sees the error.
    _writes = write.then((_) {}, onError: (_) {});
    await write;
  }

  Future<void> set(String key, String fen) =>
      _mutate((current) => {...current, key: fen});

  Future<void> remove(String key) =>
      _mutate((current) => {...current}..remove(key));
}

final diagramCorrectionsProvider =
    NotifierProvider.family<DiagramCorrections, Map<String, String>, String>(
      DiagramCorrections.new,
    );

/// The complete conversion with the user's corrections applied; what the
/// reading views and HTML export should show. Export of the *processed* book
/// uses the raw [conversionProvider] instead and carries the corrections
/// alongside, so the detected FENs are not lost.
final correctedConversionProvider = FutureProvider.autoDispose
    .family<BookConversion, String>((ref, path) async {
      final full = await ref.watch(conversionProvider(path).future);
      await ref.read(diagramCorrectionsProvider(path).notifier).loaded;
      final corrections = ref.watch(diagramCorrectionsProvider(path));
      return applyDiagramCorrections(full, corrections);
    });

/// The diagram the user last loaded onto the board, so "Set position" can save
/// an edit as a correction of that diagram.
class ActiveDiagram {
  const ActiveDiagram({
    required this.path,
    required this.key,
    required this.fen,
    required this.corrected,
  });

  final String path;
  final String key;

  /// The FEN the diagram showed when it was loaded.
  final String fen;
  final bool corrected;
}

class ActiveDiagramNotifier extends Notifier<ActiveDiagram?> {
  @override
  ActiveDiagram? build() => null;

  void set(ActiveDiagram? diagram) => state = diagram;
}

final activeDiagramProvider =
    NotifierProvider<ActiveDiagramNotifier, ActiveDiagram?>(
      ActiveDiagramNotifier.new,
    );
