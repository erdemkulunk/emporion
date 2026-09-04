import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:obtainium/catalog/data/catalog_repository.dart';
import 'package:obtainium/catalog/models.dart';

class CatalogProvider extends ChangeNotifier {
  final CatalogRepository repository;
  final void Function()? onPreferencesChanged;

  CatalogProvider({required this.repository, this.onPreferencesChanged});

  static const queryDebounce = Duration(milliseconds: 350);

  CatalogQuery _query = const CatalogQuery(text: '');
  List<CatalogEntry> _entries = const [];
  List<ProviderAccount> _accounts = const [];
  List<FdroidRepository> _fdroidRepositories = const [];
  Timer? _debounce;
  int _generation = 0;
  int _loadedPages = 1;
  int _evaluated = 0;
  bool _initialized = false;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _partial = false;
  bool _incomplete = false;
  bool _stale = false;
  String? _error;
  String? _statusMessage;

  CatalogQuery get query => _query;
  List<CatalogEntry> get entries => List.unmodifiable(_entries);
  List<ProviderAccount> get accounts => List.unmodifiable(_accounts);
  List<FdroidRepository> get fdroidRepositories =>
      List.unmodifiable(_fdroidRepositories);
  bool get initialized => _initialized;
  bool get refreshing => _refreshing;
  bool get loadingMore => _loadingMore;
  bool get partial => _partial;
  bool get incomplete => _incomplete;
  bool get stale => _stale;
  String? get error => _error;
  String? get statusMessage => _statusMessage;
  int get evaluated => _evaluated;

  Future<void> initialize() async {
    if (_initialized) return;
    await reloadConfiguration();
    _entries = await repository.searchCached(_query);
    _stale = _entries.any((e) => e.freshness != FreshnessState.fresh);
    _initialized = true;
    notifyListeners();
  }

  Future<void> reloadConfiguration() async {
    _accounts = await repository.database.accounts();
    _fdroidRepositories = await repository.database.fdroidRepositories();
    notifyListeners();
  }

  void setSearchText(String text) {
    if (text == _query.text) return;
    _query = CatalogQuery(
      text: text,
      filters: _query.filters,
      sort: _query.sort,
      pageSize: _query.pageSize,
    );
    _debounce?.cancel();
    _debounce = Timer(
      queryDebounce,
      () => unawaited(refresh(allowReorder: true)),
    );
    notifyListeners();
  }

  void setFilters(CatalogFilters filters) {
    _query = CatalogQuery(
      text: _query.text,
      filters: filters,
      sort: _query.sort,
      pageSize: _query.pageSize,
    );
    _debounce?.cancel();
    onPreferencesChanged?.call();
    unawaited(refresh(allowReorder: true));
  }

  void setSort(CatalogSort sort) {
    if (sort == _query.sort) return;
    _query = CatalogQuery(
      text: _query.text,
      filters: _query.filters,
      sort: sort,
      pageSize: _query.pageSize,
    );
    _debounce?.cancel();
    unawaited(refresh(allowReorder: true));
    onPreferencesChanged?.call();
  }

  /// Restores portable discovery preferences without starting network work.
  /// The next explicit refresh uses this query.
  void restorePreferences({
    required CatalogSort sort,
    required CatalogFilters filters,
    required int pageSize,
  }) {
    _debounce?.cancel();
    _query = CatalogQuery(
      text: '',
      filters: filters,
      sort: sort,
      pageSize: pageSize,
    );
    notifyListeners();
    onPreferencesChanged?.call();
  }

  Future<void> refresh({bool allowReorder = false}) async {
    final generation = ++_generation;
    _refreshing = true;
    _error = null;
    _statusMessage = null;
    _partial = false;
    _incomplete = false;
    _loadedPages = 1;
    notifyListeners();
    try {
      await for (final result in repository.search(_query)) {
        if (generation != _generation) return;
        _applyResult(result, allowReorder: allowReorder);
        notifyListeners();
      }
      if (_query.filters.requiresHeavyMetrics ||
          _query.sort == CatalogSort.emporionScore) {
        await evaluateMore();
      }
    } catch (error) {
      if (generation == _generation) _error = error.toString();
    } finally {
      if (generation == _generation) {
        _refreshing = false;
        notifyListeners();
      }
    }
  }

  void _applyResult(CatalogSearchResult result, {required bool allowReorder}) {
    if (allowReorder || _entries.isEmpty) {
      _entries = result.entries;
    } else {
      final incoming = {
        for (final entry in result.entries) entry.catalogKey: entry,
      };
      final merged = <CatalogEntry>[];
      for (final existing in _entries) {
        merged.add(incoming.remove(existing.catalogKey) ?? existing);
      }
      merged.addAll(incoming.values);
      _entries = merged;
    }
    _partial = result.partial;
    _incomplete = result.incomplete;
    _stale = result.stale;
    _evaluated = result.evaluated == 0 ? _evaluated : result.evaluated;
    _statusMessage = result.message;
  }

  Future<void> loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final next = await repository.searchCached(
        _query,
        offset: _loadedPages * _query.pageSize,
      );
      final seen = _entries.map((e) => e.catalogKey).toSet();
      _entries = [..._entries, ...next.where((e) => seen.add(e.catalogKey))];
      if (next.isNotEmpty) _loadedPages++;
    } catch (error) {
      _error = error.toString();
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  Future<void> enrichEntry(String catalogKey) async {
    final index = _entries.indexWhere((e) => e.catalogKey == catalogKey);
    if (index < 0) return;
    try {
      final enriched = await repository.enrich(_entries[index]);
      final updated = [..._entries];
      updated[index] = enriched;
      _entries = updated;
      notifyListeners();
    } catch (error) {
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> evaluateMore() async {
    if (_refreshing && _evaluated > 0) return;
    try {
      final result = await repository.evaluateHeavyFilters(
        _query,
        alreadyEvaluated: _evaluated,
      );
      _entries = result.entries;
      _evaluated = result.evaluated;
      _partial = result.partial;
      _statusMessage =
          result.message ??
          '${result.entries.length} matches from $_evaluated evaluated';
      notifyListeners();
    } catch (error) {
      _error = error.toString();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    super.dispose();
  }
}
