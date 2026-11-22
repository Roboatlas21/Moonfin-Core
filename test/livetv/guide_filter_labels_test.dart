import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/viewmodels/live_tv_guide_view_model.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/ui/screens/livetv/guide/guide_filter_labels.dart';

void main() {
  test('all guide filters use the same localized labels', () {
    final l10n = AppLocalizationsEn();
    expect(
      [for (final filter in GuideFilter.values) guideFilterLabel(filter, l10n)],
      [
        l10n.all,
        l10n.movies,
        l10n.series,
        l10n.sports,
        l10n.news,
        l10n.kids,
        l10n.premiere,
        l10n.favorites,
      ],
    );
  });
}
