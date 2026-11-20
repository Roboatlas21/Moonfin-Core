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

bool isPlexFreeTvChannel(MediaServerClient client, String channelId) =>
    client.serverType == ServerType.plex &&
    channelId.startsWith('channel-plex-');

/// Guide IDs are synthetic, but Plex Cloud favorites identify channels by
/// source URI and provider channel ID. DVR channels cannot be rated.
bool isPlexLiveTvChannel(MediaServerClient client, String channelId) =>
    client.serverType == ServerType.plex &&
    channelId.startsWith('channel-');

/// Plex owns both Free TV and DVR favorites. Cache source+provider IDs rather
/// than synthetic guide IDs, which can collide between PMS servers.
class PlexLiveTvFavorites {
  static const _freePrefix = 'channel-plex-';
  static const _url = 'https://epg.provider.plex.tv/settings/favoriteChannels';
  static const _freeSource = 'provider://tv.plex.provider.epg';
  static final _http = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  ));

  @visibleForTesting
  static Dio? testHttp;

  static final _pending = <String, Future<void>>{};
  // A short-lived successful read is shared by Home and search.
  static const _browseRefreshAge = Duration(seconds: 30);
  static final _lastRefresh = <String, DateTime>{};

  // The same channel ID can exist on different PMS servers. A client object
  // keeps its identity even if a network probe changes its reachable URL.
  static final _known = <String, Map<String, Map<String, dynamic>>>{};
  static Expando<int> _clientIds = Expando<int>('Plex favorite clients');
  static int _nextClientId = 0;

  static String _catalogKey(MediaServerClient client) =>
      '${client.userId ?? ''}\u0000${_clientIds[client] ??= ++_nextClientId}';

  @visibleForTesting
  static void resetForTesting() {
    _pending.clear();
    _known.clear();
    _lastRefresh.clear();
    _clientIds = Expando<int>('Plex favorite clients');
    _nextClientId = 0;
    testHttp = null;
  }

  static Preference<List<String>> _preference(String userId) =>
      Preference<List<String>>(
        key: 'plex_live_tv_favorite_keys_' + Uri.encodeComponent(userId),
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
    // A Plex Home member's cloud token is not the PMS access token.
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

  static Future<T> _serial<T>(String id, Future<T> Function() operation) async {
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
    if (raw == null && container['size'] == 0) {
      return [];
    }
    if (raw is! List || raw.any((item) => item is! Map)) {
      throw const FormatException('Invalid Plex favorite-channel list');
    }
    return [for (final row in raw) Map<String, dynamic>.from(row as Map)];
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

  static String _key(Map<String, dynamic> info) =>
      (info['source'] as String) + '\u0000' + (info['id'] as String);

  /// Free TV shares state across Plex connections; DVRs use their PMS/EPG identity.
  static String syncKey(MediaServerClient client, String channelId) {
    if (!isPlexLiveTvChannel(client, channelId) ||
        isPlexFreeTvChannel(client, channelId)) {
      return channelId;
    }
    final info = _known[_catalogKey(client)]?[channelId];
    return info == null
        ? 'plex-dvr:${_catalogKey(client)}\u0000$channelId'
        : 'plex-dvr:${_key(info)}';
  }

  static bool _matches(
    Map<String, dynamic> info,
    Map<String, dynamic> row,
  ) => row['id'] == info['id'] && row['source'] == info['source'];

  static Map<String, dynamic>? _info(
    MediaServerClient client,
    Map<String, dynamic> item,
    String channelId,
  ) {
    final free = isPlexFreeTvChannel(client, channelId);
    final source = item['PlexFavoriteSource'] ?? (free ? _freeSource : null);
    final id = item['PlexFavoriteId'] ??
        (free ? channelId.substring(_freePrefix.length) : null);
    if (source is! String || source.isEmpty || id is! String || id.isEmpty) {
      return null;
    }
    return {
      'source': source,
      'id': id,
      if (item['Name'] is String) 'title': item['Name'],
      if ((item['ImageTags'] as Map?)?['Primary'] is String)
        'thumb': (item['ImageTags'] as Map)['Primary'],
      if (item['ChannelNumber'] is String) 'vcn': item['ChannelNumber'],
    };
  }

  static Future<void> _cache(
    MediaServerClient client,
    String token,
    List<Map<String, dynamic>> rows,
  ) async {
    _checkAccount(client, token);
    final userId = client.userId!;
    final known = _known[_catalogKey(client)] ??
        const <String, Map<String, dynamic>>{};
    // Keep the whole cloud list in cache even when this device has only
    // loaded Free TV or a subset of the user's PMS channels.
    final favorites = <String>{
      for (final row in rows)
        if (row['source'] is String && row['id'] is String) _key(row),
    };
    for (final entry in known.entries) {
      if (rows.any((row) => _matches(entry.value, row))) {
        favorites.add(_key(entry.value));
      }
    }
    await GetIt.instance<UserPreferences>().set(
      _preference(userId),
      favorites.toList()..sort(),
    );
    _checkAccount(client, token);
    userDataSync.publishAll({
      for (final entry in known.entries)
        syncKey(client, entry.key): {
          'IsFavorite': favorites.contains(_key(entry.value)),
        },
    });
    _lastRefresh[userId] = DateTime.now();
  }

  static Future<void> refresh(
    MediaServerClient client, {
    bool ifStale = false,
  }) async {
    final account = _account(client);
    await _serial(account.id, () async {
      final last = _lastRefresh[account.id];
      if (ifStale &&
          last != null &&
          DateTime.now().difference(last) < _browseRefreshAge) {
        return;
      }
      final remote = await _read(client, account.token);
      _checkAccount(client, account.token);
      await _cache(client, account.token, remote);
    });
  }

  /// Home and search may use the saved cache when Plex Cloud is unavailable.
  static Future<void> refreshForBrowse(MediaServerClient client) async {
    if (client.serverType != ServerType.plex) return;
    try {
      await refresh(client, ifStale: true);
    } catch (_) {
      // Missing token, network failure or malformed response: use cached data.
    }
  }

  static Map<String, dynamic> applyToItem(
    MediaServerClient client,
    Map<String, dynamic> item,
  ) {
    final channelId = item['Id']?.toString() ?? '';
    final userId = client.userId;
    if (!isPlexLiveTvChannel(client, channelId) ||
        userId == null ||
        userId.isEmpty ||
        !GetIt.instance.isRegistered<UserPreferences>()) {
      return item;
    }
    final info = _info(client, item, channelId);
    // Without a verified machine id, don't guess the DVR favorite source.
    // Still keep its local optimistic state separate from other PMS servers.
    if (info == null) {
      return isPlexFreeTvChannel(client, channelId)
          ? item
          : {...item, 'PlexFavoriteSyncKey': syncKey(client, channelId)};
    }
    _known.putIfAbsent(_catalogKey(client), () => {})[channelId] = info;
    final favorites = GetIt.instance<UserPreferences>().get(_preference(userId));
    final userData = item['UserData'];
    return {
      ...item,
      if (!isPlexFreeTvChannel(client, channelId))
        'PlexFavoriteSyncKey': syncKey(client, channelId),
      'UserData': {
        if (userData is Map) ...userData,
        'IsFavorite': favorites.contains(_key(info)),
      },
    };
  }

  static Future<void> setFavorite(
    MediaServerClient client,
    String channelId, {
    required bool isFavorite,
  }) async {
    if (!isPlexLiveTvChannel(client, channelId)) {
      throw ArgumentError.value(channelId, 'channelId');
    }
    final account = _account(client);
    await _serial(account.id, () async {
      final info = _known[_catalogKey(client)]?[channelId] ??
          (isPlexFreeTvChannel(client, channelId)
              ? <String, dynamic>{
                  'source': _freeSource,
                  'id': channelId.substring(_freePrefix.length),
                }
              : null);
      if (info == null) {
        throw StateError('Plex DVR channel has no verified EPG provider identity');
      }
      final remote = await _read(client, account.token);
      _checkAccount(client, account.token);
      final rows = [...remote];
      final hadFavorite = rows.any((row) => _matches(info, row));
      if (isFavorite && !hadFavorite) {
        rows.add({...info});
      } else if (!isFavorite && hadFavorite) {
        rows.removeWhere((row) => _matches(info, row));
      }
      // Plex PUT replaces the whole account list: retain other PMS sources.
      if (isFavorite != hadFavorite) {
        await _write(client, account.token, rows);
      }
      await _cache(client, account.token, rows);
    });
  }
}
