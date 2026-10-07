import 'package:flutter_test/flutter_test.dart';
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

void main() {
  const p1 = SeerrQualityProfile(id: 11, name: 'Default');
  const p2 = SeerrQualityProfile(id: 12, name: 'High');
  const p3 = SeerrQualityProfile(id: 21, name: 'Other');
  const r1 = SeerrRootFolder(id: 101, path: '/tv');
  const r2 = SeerrRootFolder(id: 102, path: '/anime');
  const r3 = SeerrRootFolder(id: 201, path: '/other');

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
}
