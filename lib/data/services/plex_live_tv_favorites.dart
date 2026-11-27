import 'package:server_core/server_core.dart';

bool isPlexFreeTvChannel(MediaServerClient client, String channelId) =>
    client.serverType == ServerType.plex &&
    channelId.startsWith('channel-plex-');
