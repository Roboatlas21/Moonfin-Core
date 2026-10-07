import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/services/seerr/seerr_request_options.dart';

SeerrServiceServerDetails server({
  required int id,
  required String name,
  bool is4k = false,
  bool isDefault = false,
  required int activeProfileId,
  required String activeDirectory,
  int? animeProfileId,
  String? animeDirectory,
  List<SeerrQualityProfile> profiles = const [],
  List<SeerrRootFolder> roots = const [],
}) => SeerrServiceServerDetails(
  server: SeerrServiceServer(
    id: id,
    name: name,
    is4k: is4k,
    isDefault: isDefault,
    activeProfileId: activeProfileId,
    activeDirectory: activeDirectory,
    activeAnimeProfileId: animeProfileId,
    activeAnimeDirectory: animeDirectory,
  ),
  profiles: profiles,
  rootFolders: roots,
);

class _DelayedSeerrRepository extends Fake implements SeerrRepository {
  final listing = Completer<List<SeerrServiceServer>>();

  @override
  Future<List<SeerrServiceServer>> getSonarrServers() => listing.future;

  @override
  Future<SeerrServiceServerDetails> getSonarrServerDetails(int serverId) async =>
      server(
        id: serverId,
        name: 'Sonarr',
        activeProfileId: 11,
        activeDirectory: '/tv',
        profiles: const [SeerrQualityProfile(id: 11, name: 'Default')],
        roots: const [SeerrRootFolder(id: 101, path: '/tv')],
      );
}

void main() {
  const p1 = SeerrQualityProfile(id: 11, name: 'Default');
  const p2 = SeerrQualityProfile(id: 12, name: 'High');
  const p3 = SeerrQualityProfile(id: 21, name: 'Other');
  const r1 = SeerrRootFolder(id: 101, path: '/tv');
  const r2 = SeerrRootFolder(id: 102, path: '/anime');
  const r3 = SeerrRootFolder(id: 201, path: '/other');

  test('bounded options loader returns without waiting for Seerr', () {
    fakeAsync((clock) {
      final repository = _DelayedSeerrRepository();
      final options = SeerrRequestOptions(isTv: true);
      var completed = false;
      SeerrRequestOptions? published;

      loadCinemaSeerrOptions(
        repository,
        options,
        timeout: const Duration(seconds: 5),
      ).then((value) {
        completed = true;
        published = value;
      });
      clock.flushMicrotasks();
      expect(completed, isFalse);
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      expect(completed, isTrue);
      expect(published, isNull);

      // The late reply can finish its private fetch, but must not publish a
      // stale options instance back into a newer native picker.
      repository.listing.complete([
        const SeerrServiceServer(
          id: 1,
          name: 'Sonarr',
          activeProfileId: 11,
          activeDirectory: '/tv',
        ),
      ]);
      clock.flushMicrotasks();
      expect(completed, isTrue);
      expect(published, isNull);
    });
  });

  test('bounded options loader exposes fast valid server defaults', () async {
    final repository = _DelayedSeerrRepository();
    repository.listing.complete([
      const SeerrServiceServer(
        id: 1,
        name: 'Sonarr',
        activeProfileId: 11,
        activeDirectory: '/tv',
      ),
    ]);
    final options = SeerrRequestOptions(isTv: true);
    final result = await loadCinemaSeerrOptions(repository, options);
    expect(identical(result, options), isTrue);
    expect(result?.effectiveServerId, 1);
    expect(result?.effectiveProfileId, 11);
    expect(result?.effectiveRootFolderPath, '/tv');
  });

  test('saved ids are used only when they belong to the selected server', () {
    final options = SeerrRequestOptions(isTv: true)
      ..applyDefaults(
        const SeerrRequestDefaults(
          serverId: '1',
          profileId: '12',
          rootFolderId: '101',
        ),
      )
      ..setServers([
        server(
          id: 1,
          name: 'Sonarr',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1, p2],
          roots: const [r1, r2],
        ),
      ]);

    expect(options.effectiveServerId, 1);
    expect(options.effectiveProfileId, 12);
    expect(options.effectiveRootFolderId, 101);
    expect(options.effectiveRootFolderPath, '/tv');
    expect(options.submission?.profileId, 12);
  });

  test('stale saved ids fall back to server defaults instead of being sent', () {
    final options = SeerrRequestOptions(isTv: true)
      ..applyDefaults(
        const SeerrRequestDefaults(
          serverId: '999',
          profileId: '999',
          rootFolderId: '999',
        ),
      )
      ..setServers([
        server(
          id: 1,
          name: 'Sonarr',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1, p2],
          roots: const [r1, r2],
        ),
      ]);

    expect(options.selectedServerId, 1);
    expect(options.effectiveProfileId, 11);
    expect(options.effectiveRootFolderId, 101);
    expect(options.isValid, isTrue);
  });

  test('changing servers resets profile and root folder to that server', () {
    final options = SeerrRequestOptions(isTv: true)
      ..setServers([
        server(
          id: 1,
          name: 'One',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1, p2],
          roots: const [r1],
        ),
        server(
          id: 2,
          name: 'Two',
          activeProfileId: 21,
          activeDirectory: '/other',
          profiles: const [p3],
          roots: const [r3],
        ),
      ]);

    expect(options.selectProfile(12), isTrue);
    expect(options.selectServer(2), isTrue);
    expect(options.effectiveServerId, 2);
    expect(options.effectiveProfileId, 21);
    expect(options.effectiveRootFolderId, 201);
    expect(options.selectProfile(12), isFalse);
    expect(options.selectRootFolder(101), isFalse);
  });

  test('anime defaults use the anime profile and directory', () {
    final options = SeerrRequestOptions(isTv: true, isAnime: true)
      ..setServers([
        server(
          id: 1,
          name: 'Sonarr',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          animeProfileId: 12,
          animeDirectory: '/anime',
          profiles: const [p1, p2],
          roots: const [r1, r2],
        ),
      ]);

    expect(options.effectiveProfileId, 12);
    expect(options.effectiveRootFolderId, 102);
    expect(options.effectiveRootFolderPath, '/anime');
  });

  test('unknown native ids are rejected before submission', () {
    final options = SeerrRequestOptions(isTv: true)
      ..setServers([
        server(
          id: 1,
          name: 'Sonarr',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1],
          roots: const [r1],
        ),
      ]);

    expect(options.selectServer(999), isFalse);
    expect(options.selectProfile(999), isFalse);
    expect(options.selectRootFolder(999), isFalse);
    expect(options.submission, isNotNull);
  });

  test('4K requests only select 4K servers and never leak HD overrides', () {
    final options = SeerrRequestOptions(isTv: false, is4k: true)
      ..applyDefaults(
        const SeerrRequestDefaults(
          serverId: '1',
          profileId: '11',
          rootFolderId: '101',
        ),
      )
      ..setServers([
        server(
          id: 1,
          name: 'HD',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1],
          roots: const [r1],
        ),
        server(
          id: 2,
          name: '4K',
          is4k: true,
          activeProfileId: 21,
          activeDirectory: '/other',
          profiles: const [p3],
          roots: const [r3],
        ),
      ]);

    expect(options.eligibleServers.map((s) => s.server.id), [2]);
    expect(options.effectiveServerId, 2);
    expect(options.selectServer(1), isFalse);
    expect(options.submission?.serverId, 2);
    expect(options.submission?.rootFolder, '/other');

    options.setServers([
      server(
        id: 1,
        name: 'HD',
        activeProfileId: 11,
        activeDirectory: '/tv',
        profiles: const [p1],
        roots: const [r1],
      ),
    ]);
    expect(options.eligibleServers, isEmpty);
    expect(options.usingSeerrDefaults, isTrue);
    expect(options.submission?.serverId, isNull);
    expect(options.submission?.profileId, isNull);
    expect(options.submission?.rootFolder, isNull);
  });

  test('quality track change resets selections to the new track', () {
    final options = SeerrRequestOptions(isTv: false)
      ..setServers([
        server(
          id: 1,
          name: 'HD',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1],
          roots: const [r1],
        ),
        server(
          id: 2,
          name: '4K',
          is4k: true,
          activeProfileId: 21,
          activeDirectory: '/other',
          profiles: const [p3],
          roots: const [r3],
        ),
      ]);

    expect(options.selectServer(1), isTrue);
    options.applyDefaults(
      const SeerrRequestDefaults(
        serverId: '2',
        profileId: '21',
        rootFolderId: '201',
      ),
      is4k: true,
    );
    expect(options.selectedServerId, 2);
    expect(options.selectedProfileId, 21);
    expect(options.selectedRootFolderId, 201);
    expect(options.submission?.serverId, 2);
    expect(options.submission?.profileId, 21);
  });

  test('native selection is validated atomically without changing state', () {
    final options = SeerrRequestOptions(isTv: true)
      ..setServers([
        server(
          id: 1,
          name: 'One',
          isDefault: true,
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1],
          roots: const [r1],
        ),
        server(
          id: 2,
          name: 'Two',
          activeProfileId: 21,
          activeDirectory: '/other',
          profiles: const [p3],
          roots: const [r3],
        ),
      ]);
    final original = options.submission;

    expect(
      options.resolveForSubmission(
        const SeerrRequestSelection(
          serverId: 2,
          profileId: 11,
          rootFolderId: 201,
        ),
      ),
      isNull,
    );
    expect(
      options.resolveForSubmission(
        const SeerrRequestSelection(
          serverId: 2,
          profileId: 21,
          rootFolderId: 101,
        ),
      ),
      isNull,
    );
    expect(
      options.resolveForSubmission(
        const SeerrRequestSelection(serverId: 999),
      ),
      isNull,
    );
    expect(options.submission?.serverId, original?.serverId);
    expect(options.submission?.rootFolder, original?.rootFolder);

    final valid = options.resolveForSubmission(
      const SeerrRequestSelection(
        serverId: 2,
        profileId: 21,
        rootFolderId: 201,
      ),
    );
    expect(valid?.serverId, 2);
    expect(valid?.profileId, 21);
    expect(valid?.rootFolder, '/other');
  });

  test('missing selections are invalid when the server offers choices', () {
    final options = SeerrRequestOptions(isTv: true)
      ..setServers([
        server(
          id: 1,
          name: 'One',
          activeProfileId: 11,
          activeDirectory: '/tv',
          profiles: const [p1],
          roots: const [r1],
        ),
      ]);

    expect(
      options.resolveForSubmission(
        const SeerrRequestSelection(serverId: 1),
      ),
      isNull,
    );
    expect(
      options.resolveForSubmission(
        const SeerrRequestSelection(
          serverId: 1,
          profileId: 11,
          rootFolderId: 101,
        ),
      )?.rootFolder,
      '/tv',
    );
  });

  test('explicit Seerr defaults are safe when advanced data is absent', () {
    final options = SeerrRequestOptions(isTv: true);
    expect(options.usingSeerrDefaults, isTrue);
    expect(options.submission?.serverId, isNull);
    options.setServers([]);
    expect(options.selectServer(1), isFalse);
    expect(options.submission?.rootFolder, isNull);
  });

}
