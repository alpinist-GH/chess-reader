import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/app_settings.dart';

/// Reading-view modes stored in [LibraryState.viewMode]: the original PDF
/// pages, or the reflowed HTML reading view.
const kViewModePdf = 'pdf';
const kViewModeHtml = 'html';

/// A saved location in a book the user can jump back to.
class Bookmark {
  const Bookmark({required this.page, required this.label});

  /// PDF page number, or EPUB chapter index + 1.
  final int page;
  final String label;

  Map<String, dynamic> toJson() => {'page': page, 'label': label};
  factory Bookmark.fromJson(Map<String, dynamic> j) =>
      Bookmark(page: j['page'] as int, label: j['label'] as String);
}

/// Library state persisted across launches: which books were opened, where
/// the user left off in each, and their bookmarks.
class LibraryState {
  const LibraryState({
    this.recentPaths = const [],
    this.lastPage = const {},
    this.bookmarks = const {},
    this.viewMode = const {},
  });

  /// Most-recently-opened first.
  final List<String> recentPaths;

  /// path → last viewed page (PDF page / EPUB chapter index + 1).
  final Map<String, int> lastPage;

  /// path → bookmarks in that book.
  final Map<String, List<Bookmark>> bookmarks;

  /// path → reading view: 'pdf' (original pages) or 'html' (reflowed). PDF
  /// only; absent until the user chooses.
  final Map<String, String> viewMode;

  String? get mostRecent => recentPaths.isEmpty ? null : recentPaths.first;

  LibraryState copyWith({
    List<String>? recentPaths,
    Map<String, int>? lastPage,
    Map<String, List<Bookmark>>? bookmarks,
    Map<String, String>? viewMode,
  }) {
    return LibraryState(
      recentPaths: recentPaths ?? this.recentPaths,
      lastPage: lastPage ?? this.lastPage,
      bookmarks: bookmarks ?? this.bookmarks,
      viewMode: viewMode ?? this.viewMode,
    );
  }
}

class LibraryStore extends Notifier<LibraryState> {
  static const _kRecent = 'lib.recent';
  static const _kLastPage = 'lib.lastPage';
  static const _kBookmarks = 'lib.bookmarks';
  static const _kViewMode = 'lib.viewMode';
  static const _maxRecent = 12;

  @override
  LibraryState build() {
    final p = ref.read(sharedPrefsProvider);
    final recent = p.getStringList(_kRecent) ?? const [];
    // Each stored blob decodes independently and best-effort: one corrupt
    // value must not throw during provider build and block startup.
    final lastPage = <String, int>{};
    final lastPageRaw = p.getString(_kLastPage);
    if (lastPageRaw != null) {
      try {
        (jsonDecode(lastPageRaw) as Map<String, dynamic>)
            .forEach((k, v) => lastPage[k] = v as int);
      } catch (_) {}
    }
    final bookmarks = <String, List<Bookmark>>{};
    final bmRaw = p.getString(_kBookmarks);
    if (bmRaw != null) {
      try {
        (jsonDecode(bmRaw) as Map<String, dynamic>).forEach((k, v) {
          bookmarks[k] = [
            for (final e in v as List)
              Bookmark.fromJson(e as Map<String, dynamic>)
          ];
        });
      } catch (_) {}
    }
    final viewMode = <String, String>{};
    final vmRaw = p.getString(_kViewMode);
    if (vmRaw != null) {
      try {
        (jsonDecode(vmRaw) as Map<String, dynamic>)
            .forEach((k, v) => viewMode[k] = v as String);
      } catch (_) {}
    }
    return LibraryState(
      recentPaths: recent,
      lastPage: lastPage,
      bookmarks: bookmarks,
      viewMode: viewMode,
    );
  }

  void recordOpened(String path) {
    final recent = [path, ...state.recentPaths.where((p) => p != path)]
        .take(_maxRecent)
        .toList();
    state = state.copyWith(recentPaths: recent);
    ref.read(sharedPrefsProvider).setStringList(_kRecent, recent);
  }

  /// Drops a book from the recent list (its bookmarks / resume page are kept
  /// in case it's reopened).
  void removeRecent(String path) {
    final recent = state.recentPaths.where((p) => p != path).toList();
    state = state.copyWith(recentPaths: recent);
    ref.read(sharedPrefsProvider).setStringList(_kRecent, recent);
  }

  void recordPage(String path, int page) {
    // Called from scroll listeners on every notification; skip the JSON
    // encode + prefs write when the position hasn't actually changed.
    if (state.lastPage[path] == page) return;
    final updated = {...state.lastPage, path: page};
    state = state.copyWith(lastPage: updated);
    ref.read(sharedPrefsProvider).setString(_kLastPage, jsonEncode(updated));
  }

  int? lastPageFor(String path) => state.lastPage[path];

  /// 'pdf' or 'html', or null if the user hasn't chosen for this book yet.
  String? viewModeFor(String path) => state.viewMode[path];

  void setViewMode(String path, String mode) {
    final updated = {...state.viewMode, path: mode};
    state = state.copyWith(viewMode: updated);
    ref.read(sharedPrefsProvider).setString(_kViewMode, jsonEncode(updated));
  }

  List<Bookmark> bookmarksFor(String path) => state.bookmarks[path] ?? const [];

  void addBookmark(String path, Bookmark bookmark) {
    final list = [...bookmarksFor(path), bookmark]
      ..sort((a, b) => a.page.compareTo(b.page));
    _saveBookmarks(path, list);
  }

  void removeBookmark(String path, int index) {
    final list = [...bookmarksFor(path)]..removeAt(index);
    _saveBookmarks(path, list);
  }

  void _saveBookmarks(String path, List<Bookmark> list) {
    final updated = {...state.bookmarks, path: list};
    state = state.copyWith(bookmarks: updated);
    ref.read(sharedPrefsProvider).setString(
          _kBookmarks,
          jsonEncode(updated.map(
              (k, v) => MapEntry(k, [for (final b in v) b.toJson()]))),
        );
  }
}

final libraryStoreProvider =
    NotifierProvider<LibraryStore, LibraryState>(LibraryStore.new);
