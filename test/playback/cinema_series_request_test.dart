import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/services/seerr/seerr_seasons.dart';
import 'package:moonfin/playback/cinema_mode_controller.dart';

void main() {
  test('partial series offers missing seasons but excludes available or requested ones', () {
    final details = SeerrTvDetails(
      id: 42,
      numberOfSeasons: 3,
      mediaInfo: const SeerrMediaInfo(
        status: SeerrMediaStatus.partiallyAvailable,
        seasons: [SeerrSeasonAvailability(seasonNumber: 1, status: 5)],
        requests: [
          SeerrRequest(
            id: 1,
            status: 2,
            type: 'tv',
            seasons: [SeerrSeasonRequest(id: 1, seasonNumber: 2, status: 2)],
          ),
        ],
      ),
    );
    expect(cinemaRequestableSeasons(details), {3});
    expect(cinemaTvSeerrState(details), CinemaSeerrState.request);
    expect(
      cinemaTvSeerrState(details, excludedSeasons: {3}),
      CinemaSeerrState.requested,
    );
    expect(
      cinemaTvSeerrState(const SeerrTvDetails(
        id: 42,
        numberOfSeasons: 2,
        mediaInfo: SeerrMediaInfo(
          status: SeerrMediaStatus.partiallyAvailable,
          seasons: [SeerrSeasonAvailability(seasonNumber: 1, status: 5)],
          requests: [
            SeerrRequest(
              id: 1, type: 'tv', status: SeerrRequest.statusApproved,
              seasons: [SeerrSeasonRequest(id: 1, seasonNumber: 2, status: 2)],
            ),
          ],
        ),
      )),
      CinemaSeerrState.requested,
    );
    expect(
      cinemaTvSeerrState(const SeerrTvDetails(
        id: 42,
        mediaInfo: SeerrMediaInfo(status: SeerrMediaStatus.partiallyAvailable),
      )),
      CinemaSeerrState.partiallyAvailable,
    );
    expect(
      cinemaTvSeerrState(
        const SeerrTvDetails(
          id: 42,
          mediaInfo: SeerrMediaInfo(status: 6),
          numberOfSeasons: 3,
        ),
      ),
      CinemaSeerrState.hidden,
    );
    expect(
      cinemaTvSeerrState(const SeerrTvDetails(id: 42)),
      CinemaSeerrState.hidden,
    );
  });

  test('native All Seasons uses Seerr all, not enumerated seasons', () {
    final selection = cinemaTvRequestSelection(
      {'allSeasons': true, 'seasons': <int>[]},
      {2, 5},
      const SeerrQuotaDetail(limit: 4, remaining: 2),
    );
    expect(selection, isNotNull);
    expect(selection!.allSeasons, isTrue);
    expect(selection.seasons, isNull);
  });

  test('native selection rejects malformed and unrequestable seasons', () {
    for (final value in [
      {'seasons': [2]},
      {'allSeasons': false, 'seasons': [2.0]},
      {'allSeasons': false, 'seasons': [99]},
      {'allSeasons': false, 'seasons': <int>[]},
      {'allSeasons': true, 'seasons': [2]},
    ]) {
      expect(cinemaTvRequestSelection(value, {2, 5}, null), isNull);
    }
    expect(
      cinemaTvRequestSelection(
        {'allSeasons': true, 'seasons': <int>[]},
        <int>{},
        null,
      ),
      isNull,
    );
  });
  test('season coverage keeps HD, 4K and completed requests separate', () {
    const info = SeerrMediaInfo(
      seasons: [
        SeerrSeasonAvailability(seasonNumber: 1, status: SeerrMediaStatus.available),
        SeerrSeasonAvailability(seasonNumber: 2, status4k: SeerrMediaStatus.available),
      ],
      requests: [
        SeerrRequest(
          id: 1, type: 'tv', status: SeerrRequest.statusApproved,
          seasons: [SeerrSeasonRequest(id: 1, seasonNumber: 3, status: 2)],
        ),
        SeerrRequest(
          id: 2, type: 'tv', status: SeerrRequest.statusPending, is4k: true,
          seasons: [SeerrSeasonRequest(id: 2, seasonNumber: 4, status: 1)],
        ),
        SeerrRequest(
          id: 3, type: 'tv', status: SeerrRequest.statusCompleted,
          seasons: [SeerrSeasonRequest(id: 3, seasonNumber: 5, status: 5)],
        ),
      ],
    );
    expect(seerrUnavailableOrRequestedSeasons(info, is4k: false), {1, 3});
    expect(seerrUnavailableOrRequestedSeasons(info, is4k: true), {2, 4});
    expect(
      cinemaRequestableSeasons(const SeerrTvDetails(
        id: 42, numberOfSeasons: 5, mediaInfo: info,
      )),
      {2, 4, 5},
    );
  });

}
