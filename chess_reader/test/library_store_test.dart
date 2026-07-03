import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_reader/core/persistence/library_store.dart';
import 'package:chess_reader/core/settings/app_settings.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('recent books are de-duplicated and most-recent-first', () async {
    final c = await _container();
    final store = c.read(libraryStoreProvider.notifier);
    store.recordOpened('a.pdf');
    store.recordOpened('b.pdf');
    store.recordOpened('a.pdf'); // re-open moves to front, no dupe
    expect(c.read(libraryStoreProvider).recentPaths, ['a.pdf', 'b.pdf']);
    expect(c.read(libraryStoreProvider).mostRecent, 'a.pdf');
  });

  test('last page persists and reloads', () async {
    final c1 = await _container();
    c1.read(libraryStoreProvider.notifier).recordPage('book.pdf', 42);
    // A new store over the same (mock) prefs reads the saved value.
    final prefs = c1.read(sharedPrefsProvider);
    final c2 = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(c2.dispose);
    expect(
        c2.read(libraryStoreProvider.notifier).lastPageFor('book.pdf'), 42);
  });

  test('bookmarks add, sort by page, and remove', () async {
    final c = await _container();
    final store = c.read(libraryStoreProvider.notifier);
    store.addBookmark('book.pdf', const Bookmark(page: 30, label: 'Page 30'));
    store.addBookmark('book.pdf', const Bookmark(page: 10, label: 'Page 10'));
    final marks = store.bookmarksFor('book.pdf');
    expect(marks.map((b) => b.page).toList(), [10, 30]);
    store.removeBookmark('book.pdf', 0);
    expect(store.bookmarksFor('book.pdf').single.page, 30);
  });

  test('recordPage with an unchanged page is a no-op', () async {
    final c = await _container();
    final store = c.read(libraryStoreProvider.notifier);
    store.recordPage('book.pdf', 7);
    final before = c.read(libraryStoreProvider);
    store.recordPage('book.pdf', 7); // same page: no new state, no write
    expect(identical(c.read(libraryStoreProvider), before), isTrue);
  });

  test('corrupt persisted JSON is ignored instead of breaking build', () async {
    SharedPreferences.setMockInitialValues({
      'lib.lastPage': 'not json {{{',
      'lib.bookmarks': '[1,2,3]', // wrong shape
      'lib.viewMode': '{"a.pdf": 5}', // wrong value type
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    final state = c.read(libraryStoreProvider); // must not throw
    expect(state.lastPage, isEmpty);
    expect(state.bookmarks, isEmpty);
    expect(state.viewMode, isEmpty);
  });

  test('settings persist piece set, theme, engine and text scale', () async {
    final c = await _container();
    final s = c.read(settingsProvider.notifier);
    s.setBoardTheme('green');
    s.setEngineThreads(8);
    s.setEngineDepth(22);
    s.setTextScale(1.4);
    final settings = c.read(settingsProvider);
    expect(settings.boardThemeName, 'green');
    expect(settings.engineThreads, 8);
    expect(settings.engineDepth, 22);
    expect(settings.textScale, 1.4);
    expect(settings.boardColors, isNotNull);
  });
}
