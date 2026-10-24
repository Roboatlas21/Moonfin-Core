import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/web_subtitle_text.dart';

void main() {
  test('secondary cues hide SRT alignment tags and preserve emphasis', () {
    for (var alignment = 1; alignment <= 9; alignment++) {
      expect(
        secondaryWebVttCueText('  {\\an$alignment}<i>Translation</i>'),
        '<c.moonfin-secondary><i>Translation</i></c>',
      );
    }
  });

  test('ordinary WebVTT markup and dialogue remain intact', () {
    const text = '<v Speaker><b>Hello</b> &amp; <u>goodbye</u>\nNext line';
    expect(secondaryWebVttCueText(text), '<c.moonfin-secondary>$text</c>');
  });

  test('alignment-looking text within dialogue is not stripped', () {
    const text = r'The tag {\an8} belongs to this sentence.';
    expect(secondaryWebVttCueText(text), '<c.moonfin-secondary>$text</c>');
  });
}
