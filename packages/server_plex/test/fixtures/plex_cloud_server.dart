import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(
  StreamChannel<Object?> channel,
  String testOrigin,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  channel.sink.add('http://127.0.0.1:${server.port}');
  var redirects = 0, followed = 0;
  var favorites = <dynamic>[];
  await for (final request in server) {
    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', testOrigin)
      ..set('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        request.headers.value('Access-Control-Request-Headers') ??
            'Content-Type',
      )
      ..contentType = ContentType.json;
    final path = request.uri.path;
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
    } else if (path.startsWith('/redirect/')) {
      redirects++;
      response.statusCode = HttpStatus.temporaryRedirect;
      response.headers.set(HttpHeaders.locationHeader, '/followed');
    } else if (path == '/followed') {
      followed++;
    } else if (path == '/counts') {
      response.write(
        jsonEncode({'redirects': redirects, 'followed': followed}),
      );
    } else if (path == '/trickle') {
      response.bufferOutput = false;
      response.headers.set('X-Content-Type-Options', 'nosniff');
      try {
        for (var i = 0; i < 25; i++) {
          response.write(' ');
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        response.write('{}');
      } on IOException {
        // The deadline closes the connection while the fixture is still writing.
      }
    } else if (path == '/livetv/dvrs') {
      response.write('{"MediaContainer":{"Dvr":[]}}');
    } else if (path == '/lineups/plex/channels') {
      response.write(
        '{"MediaContainer":{"Channel":[{"id":"one","title":"One"}]}}',
      );
    } else if (path == '/settings/favoriteChannels' &&
        request.headers.value('X-Plex-Token') == 'fixture') {
      if (request.method == 'PUT') {
        favorites = jsonDecode(await utf8.decoder.bind(request).join()) as List;
      }
      response.write(
        jsonEncode({
          'MediaContainer': {'FavoriteChannel': favorites},
        }),
      );
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }
}
