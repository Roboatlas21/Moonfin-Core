@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/web_subtitle_overlay_web.dart';
import 'package:web/web.dart' as web;

class _FastTimer implements Timer {
  bool _active = true;
  int _ticks = 0;

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => _ticks;
}

Future<void> _simulateLoadTimeout(Future<void> Function() load) =>
    runZoned<Future<void>>(
      load,
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (_, _, _, _, callback) {
          final timer = _FastTimer();
          scheduleMicrotask(() {
            for (var i = 0; i < 150 && timer.isActive; i++) {
              timer._ticks++;
              callback(timer);
            }
          });
          return timer;
        },
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ASS and PGS initialization can retry after timeout', () async {
    web.window.delete('JASSUB'.toJS);
    web.window.delete('libpgs'.toJS);
    final overlay = WebSubtitleOverlay(web.HTMLVideoElement());
    try {
      await _simulateLoadTimeout(
        () => overlay.show('https://example.org/old.ass', 'ass'),
      );
      await _simulateLoadTimeout(
        () => overlay.show('https://example.org/old.pgs', 'pgs'),
      );

      final script = web.HTMLScriptElement()..text = '''
        window.moonfinOverlayRetries = 0;
        window.JASSUB = class {
          constructor(options) { window.moonfinOverlayRetries++; }
          setCurrentTime() {}
          destroy() {}
        };
        window.libpgs = { PgsRenderer: class {
          constructor(options) { window.moonfinOverlayRetries++; }
          dispose() {}
        } };
      ''';
      web.document.head!.appendChild(script);
      script.remove();

      await overlay.show('https://example.org/new.ass', 'ass');
      await overlay.show('https://example.org/new.pgs', 'pgs');
      expect(
        web.window.getProperty<JSNumber>('moonfinOverlayRetries'.toJS).toDartInt,
        2,
      );
    } finally {
      overlay.dispose();
      web.window.delete('JASSUB'.toJS);
      web.window.delete('libpgs'.toJS);
      web.window.delete('moonfinOverlayRetries'.toJS);
    }
  });
}
