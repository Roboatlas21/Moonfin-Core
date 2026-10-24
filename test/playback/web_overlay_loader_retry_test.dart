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
    final errors = <String>[];
    final overlay = WebSubtitleOverlay(
      web.HTMLVideoElement(),
      onError: errors.add,
    );
    try {
      await _simulateLoadTimeout(
        () => overlay.show('https://example.org/old.ass', 'ass'),
      );
      await _simulateLoadTimeout(
        () => overlay.show('https://example.org/old.pgs', 'pgs'),
      );
      expect(errors, hasLength(2));
      expect(errors[0], contains('ASS subtitle renderer failed'));
      expect(errors[1], contains('PGS subtitle renderer failed'));

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
      expect(errors, hasLength(2));

      final failures = web.HTMLScriptElement()..text = '''
        window.JASSUB = class {
          constructor() { throw new Error('ASS constructor failed'); }
        };
        window.libpgs = { PgsRenderer: class {
          constructor() { throw new Error('PGS constructor failed'); }
        } };
      ''';
      web.document.head!.appendChild(failures);
      failures.remove();
      await overlay.show('https://example.org/fail.ass', 'ass');
      await overlay.show('https://example.org/fail.pgs', 'pgs');
      expect(errors, hasLength(4));
      expect(errors[2], contains('ASS subtitle renderer failed'));
      expect(errors[3], contains('PGS subtitle renderer failed'));

      final missingCtor = web.HTMLScriptElement()
        ..text = 'window.libpgs = {};';
      web.document.head!.appendChild(missingCtor);
      missingCtor.remove();
      await overlay.show('https://example.org/missing.pgs', 'pgs');
      expect(errors.last, contains('PGS subtitle renderer failed'));
      expect(errors, hasLength(5));
    } finally {
      overlay.dispose();
      web.window.delete('JASSUB'.toJS);
      web.window.delete('libpgs'.toJS);
      web.window.delete('moonfinOverlayRetries'.toJS);
    }
  });
}
