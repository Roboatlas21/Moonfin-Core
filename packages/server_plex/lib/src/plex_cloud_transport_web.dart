import 'dart:async';
import 'dart:typed_data';

import 'package:dio/browser.dart';
import 'package:dio/dio.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

void configurePlexCloudTransport(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is BrowserHttpClientAdapter) {
    dio.httpClientAdapter = _PlexCloudAdapter(adapter);
  }
}

// Dio uses XMLHttpRequest on web, which follows redirects before Dart sees them.
// BrowserClient uses Fetch and can reject a redirect before the next request.
class _PlexCloudAdapter implements HttpClientAdapter {
  _PlexCloudAdapter(this._defaultAdapter);

  final BrowserHttpClientAdapter _defaultAdapter;
  final _active = <void Function()>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.followRedirects) {
      return _defaultAdapter.fetch(options, requestStream, cancelFuture);
    }

    final abort = Completer<void>();
    void abortRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    final connect = options.connectTimeout ?? Duration.zero;
    final receive = options.receiveTimeout ?? Duration.zero;
    var receivedHeaders = false;
    final client = BrowserClient()
      ..withCredentials =
          options.extra['withCredentials'] as bool? ??
          _defaultAdapter.withCredentials;

    Future<ResponseBody> transfer() async {
      final request = http.AbortableRequest(
        options.method,
        options.uri,
        abortTrigger: abort.future,
      )..followRedirects = false;
      options.headers.forEach((key, value) {
        request.headers[key] = value is Iterable
            ? value.join(', ')
            : value.toString();
      });
      if (requestStream != null) {
        request.bodyBytes = await http.ByteStream(requestStream).toBytes();
      }

      final sending = client.send(request);
      final response = connect > Duration.zero
          ? await sending.timeout(connect)
          : await sending;
      receivedHeaders = true;
      final body = receive > Duration.zero
          ? response.stream.timeout(receive)
          : response.stream;
      final bytes = await http.ByteStream(body).toBytes();
      return ResponseBody(
        Stream.value(bytes),
        response.statusCode,
        headers: {
          for (final h in response.headers.entries) h.key: [h.value],
        },
        statusMessage: response.reasonPhrase,
      );
    }

    _active.add(abortRequest);
    cancelFuture?.then((_) => abortRequest());
    // Keep the browser adapter's total deadline as well as its header and body timeouts.
    final total = connect + receive;
    try {
      final pending = transfer();
      return total > Duration.zero
          ? await pending.timeout(total)
          : await pending;
    } on TimeoutException catch (error) {
      if (!receivedHeaders && connect > Duration.zero) {
        throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: connect,
          error: error,
        );
      }
      throw DioException.receiveTimeout(
        requestOptions: options,
        timeout: error.duration ?? total,
        error: error,
      );
    } on http.ClientException catch (error) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: error.message,
        error: error,
      );
    } finally {
      _active.remove(abortRequest);
      abortRequest();
      client.close();
    }
  }

  @override
  void close({bool force = false}) {
    if (force) {
      for (final abort in _active) {
        abort();
      }
    }
    _defaultAdapter.close(force: force);
  }
}
