import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/services/seerr/seerr_seasons.dart';

void main() {
  test('TV quota counts requestable seasons, not already-owned seasons', () {
    expect(
      seerrTvQuotaNeeded(
        allSeasons: true,
        requestableSeasons: {2, 5},
        selectedSeasons: const [],
      ),
      2,
    );
    expect(
      seerrTvQuotaNeeded(
        allSeasons: false,
        requestableSeasons: {2, 5},
        selectedSeasons: [5, 5],
      ),
      1,
    );
  });

  test('limited quota blocks oversized requests but permits smaller ones', () {
    const quota = SeerrQuotaDetail(limit: 5, remaining: 1);
    expect(seerrQuotaBlocked(quota, 1), isFalse);
    expect(seerrQuotaBlocked(quota, 2), isTrue);
    expect(
      seerrQuotaBlocked(
        const SeerrQuotaDetail(limit: 5, remaining: 5, restricted: true),
        1,
      ),
      isTrue,
    );
  });

  test('unknown or unlimited quota does not block a valid request', () {
    expect(seerrQuotaBlocked(null, 3), isFalse);
    expect(
      seerrQuotaBlocked(const SeerrQuotaDetail(limit: 0, restricted: true), 3),
      isFalse,
    );
    expect(
      seerrQuotaBlocked(const SeerrQuotaDetail(limit: 5), 3),
      isFalse,
    );
  });
}
