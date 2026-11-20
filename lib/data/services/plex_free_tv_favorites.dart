import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';

import '../../auth/models/user.dart';
import '../../auth/repositories/user_repository.dart';
import '../../preference/user_preferences.dart';
import 'user_data_sync.dart';

/// Plex Cloud and PMS connections use the same channel IDs and Plex account.
bool isPlexFreeTvChannel(MediaServerClient client, String channelId) =>
    channelId.startsWith('channel-plex-') &&
    client.serverType == ServerType.plex;

/// Plex owns one account-level list, including favorites from other TV sources.
/// Keep our existing per-account preference as a cache, never as a second source
/// of truth after the first successful cloud read.
class PlexFreeTvFavorites {
  static const _prefix = 'channel-plex-';
  static const _url = 'https://epg.provider.plex.tv/settings/favoriteChannels';
  static const _source = 'provider://tv.plex.provider.epg';
  static final _http = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  ));

  @visibleForTesting
  static Dio? testHttp;

  // Serialize whole-list reads/writes across channels on this device.
  static final _pending = <String, Future<void>>{};
  static final _known = <String, Map<String, Map<String, dynamic>>>{};

  @visibleForTesting
  static void resetForTesting() {
    _pending.clear();
    _known.clear();
    testHttp = null;
  }

  static Preference<List<String>> _preference(String userId) =>
      Preference<List<String>>(
        key: 'plex_free_tv_favorites_' + Uri.encodeComponent(userId),
        defaultValue: const [],
      );

  static ({String id, String token}) _account(MediaServerClient client) {
    final user = GetIt.instance.isRegistered<UserRepository>()
        ? GetIt.instance<UserRepository>().currentUser
        : null;
    if (client.serverType != ServerType.plex ||
        user is! PrivateUser ||
        user.id != client.userId ||
        user.plexToken == null ||
        user.plexToken!.isEmpty) {
      throw StateError('No Plex account token for this user');
    }
    // Never send the PMS access token or another Home member's token.
    return (id: user.id, token: user.plexToken!);
  }

  static Map<String, String> _headers(
    MediaServerClient client,
    String token,
  ) => {
        'X-Plex-Token': token,
        'X-Plex-Client-Identifier': client.deviceInfo.id,
        'X-Plex-Product': client.deviceInfo.appName,
        'X-Plex-Provider-Version': '5.1',
        'Accept': 'application/json',
      };

  static void _checkAccount(MediaServerClient client, String token) {
    if (_account(client).token != token) {
      throw StateError('Plex account changed while saving favorites');
    }
  }

  static Future<T> _serial<T>(
    String id,
    Future<T> Function() operation,
  ) async {
    final previous = _pending[id];
    final gate = Completer<void>();
    _pending[id] = gate.future;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      gate.complete();
      if (identical(_pending[id], gate.future)) _pending.remove(id);
    }
  }

  static Future<List<Map<String, dynamic>>> _read(
    MediaServerClient client,
    String token,
  ) async {
    final response = await (testHttp ?? _http).get<Map<String, dynamic>>(
      _url,
      options: Options(headers: _headers(client, token)),
    );
    final container = response.data?['MediaContainer'];
    if (container is! Map) {
      throw const FormatException('Invalid Plex favorite-channel response');
    }
    final raw = container['FavoriteChannel'];
    if (raw == null && (container['size'] == 0 || container['size'] == null)) {
      return [];
    }
    if (raw is! List || raw.any((item) => item is! Map)) {
      throw const FormatException('Invalid Plex favorite-channel list');
    }
    return [
      for (final row in raw) Map<String, dynamic>.from(row as Map),
    ];
  }

  static Future<void> _write(
    MediaServerClient client,
    String token,
    List<Map<String, dynamic>> rows,
  ) async {
    await (testHttp ?? _http).put<void>(
      _url,
      data: rows,
      options: Options(
        headers: {..._headers(client, token), 'Content-Type': 'application/json'},
      ),
    );
  }

  static bool _isFree(String userId, Map<String, dynamic> row) {
    final source = row['source'];
    final id = row['id'];
    return id is String &&
        (source == _source ||
            (source is String &&
                source.startsWith('provider://') &&
                _known[userId]?.containsKey(_prefix + id) == true));
  }

  static Map<String, dynamic> _newRow(String userId, String channelId) {
    final meta = _known[userId]?[channelId];
    return {
      'source': _source,
      'id': channelId.substring(_prefix.length),
      if (meta?['title'] is String) 'title': meta!['title'],
      if (meta?['thumb'] is String) 'thumb': meta!['thumb'],
    };
  }

  static Future<void> _cache(
    MediaServerClient client,
    String token,
    List<Map<String, dynamic>> rows,
  ) async {
    _checkAccount(client, token);
    final userId = client.userId!;
    final ids = {
      for (final row in rows)
        if (_isFree(userId, row)) _prefix + (row['id'] as String),
    };
    await GetIt.instance<UserPreferences>()
        .set(_preference(userId), ids.toList()..sort());
    // Update visible guide hearts and Favorites rows without reloading channels.
    _checkAccount(client, token);
    userDataSync.publishAll({
      for (final id in _known[userId]?.keys ?? const <String>[])
        id: {'IsFavorite': ids.contains(id)},
    });
  }

  static Future<void> refresh(MediaServerClient client) async {
    final account = _account(client);
    await _serial(account.id, () async {
      final remote = await _read(client, account.token);
      _checkAccount(client, account.token);
      await _cache(client, account.token, remote);
    });
  }

  static Map<String, dynamic> applyToItem(
    MediaServerClient client,
    Map<String, dynamic> item,
  ) {
    final id = item['Id']?.toString() ?? '';
    final userId = client.userId;
    if (!isPlexFreeTvChannel(client, id) ||
        userId == null ||
        userId.isEmpty ||
        !GetIt.instance.isRegistered<UserPreferences>()) {
      return item;
    }
    _known.putIfAbsent(userId, () => {})[id] = {
      if (item['Name'] is String) 'title': item['Name'],
      if ((item['ImageTags'] as Map?)?['Primary'] is String)
        'thumb': (item['ImageTags'] as Map)['Primary'],
    };
    final favorites = GetIt.instance<UserPreferences>().get(_preference(userId));
    final userData = item['UserData'];
    return {
      ...item,
      'UserData': {
        if (userData is Map) ...userData,
        'IsFavorite': favorites.contains(id),
      },
    };
  }

  static Future<void> setFavorite(
    MediaServerClient client,
    String channelId, {
    required bool isFavorite,
  }) async {
    if (!isPlexFreeTvChannel(client, channelId)) {
      throw ArgumentError.value(channelId, 'channelId');
    }
    final account = _account(client);
    await _serial(account.id, () async {
      final remote = await _read(client, account.token);
      _checkAccount(client, account.token);
      final rows = [...remote];
      final key = channelId.substring(_prefix.length);
      final hadFavorite = rows.any(
        (row) => row['id'] == key && _isFree(account.id, row),
      );
      if (isFavorite && !hadFavorite) {
        rows.add(_newRow(account.id, channelId));
      } else if (!isFavorite && hadFavorite) {
        rows.removeWhere(
          (row) => row['id'] == key && _isFree(account.id, row),
        );
      }
      // A PUT replaces the entire account list, so retain every other entry
      // exactly as Plex returned it, including other servers' DVR favorites.
      if (isFavorite != hadFavorite) {
        await _write(client, account.token, rows);
      }
      await _cache(client, account.token, rows);
    });
  }
}
