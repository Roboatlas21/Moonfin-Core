import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/ui/widgets/seerr/seerr_advanced_request_options.dart';

class _SlowServerRepository extends Fake implements SeerrRepository {
  final pending = Completer<List<SeerrServiceServer>>();
  final requested = Completer<void>();

  @override
  Future<List<SeerrServiceServer>> getSonarrServers() {
    requested.complete();
    return pending.future;
  }

  @override
  Future<SeerrServiceServerDetails> getSonarrServerDetails(int id) async {
    return SeerrServiceServerDetails(
      server: SeerrServiceServer(
        id: id,
        name: 'Sonarr',
        activeProfileId: 11,
        activeDirectory: '/tv',
      ),
      profiles: const [SeerrQualityProfile(id: 11, name: 'HD')],
      rootFolders: const [SeerrRootFolder(id: 101, path: '/tv')],
    );
  }
}

SeerrServiceServerDetails _server({
  required int id,
  bool is4k = false,
  bool isDefault = false,
  int activeProfileId = 11,
  String activeDirectory = '/tv',
  int? animeProfileId,
  String? animeDirectory,
  List<SeerrQualityProfile> profiles = const [
    SeerrQualityProfile(id: 11, name: 'Default'),
    SeerrQualityProfile(id: 12, name: 'Alternate'),
  ],
  List<SeerrRootFolder> folders = const [
    SeerrRootFolder(id: 101, path: '/tv'),
    SeerrRootFolder(id: 102, path: '/alternate'),
  ],
}) => SeerrServiceServerDetails(
  server: SeerrServiceServer(
    id: id,
    name: 'Sonarr $id',
    is4k: is4k,
    isDefault: isDefault,
    activeProfileId: activeProfileId,
    activeDirectory: activeDirectory,
    activeAnimeProfileId: animeProfileId,
    activeAnimeDirectory: animeDirectory,
  ),
  profiles: profiles,
  rootFolders: folders,
);

class _PartialServerRepository extends Fake implements SeerrRepository {
  @override
  Future<List<SeerrServiceServer>> getSonarrServers() async => [
    _server(id: 1).server,
    _server(id: 2).server,
  ];

  @override
  Future<SeerrServiceServerDetails> getSonarrServerDetails(int id) async {
    if (id == 1) throw StateError('Sonarr 1 offline');
    return _server(id: id);
  }
}

void main() {
  setUp(() async => GetIt.instance.reset());
  tearDown(() async => GetIt.instance.reset());

  test('closing the dialog during load never notifies a disposed controller',
      () async {
    final repo = _SlowServerRepository();
    GetIt.instance.registerSingletonAsync<SeerrRepository>(() async => repo);
    await GetIt.instance.allReady();

    final controller = SeerrAdvancedRequestController(isTv: true);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final pending = controller.load();
    expect(controller.loading, isTrue);
    await repo.requested.future; // The fetch is really in flight.
    controller.dispose();

    repo.pending.complete([
      const SeerrServiceServer(
        id: 1,
        name: 'Sonarr',
        activeProfileId: 11,
        activeDirectory: '/tv',
      ),
    ]);
    await pending;
    expect(notifications, 1);
    expect(controller.loading, isFalse);
    // A late nested picker callback must also be harmless.
    controller.onServerChanged(1);
    controller.onProfileChanged(11);
    controller.onRootFolderChanged(101);
    controller.applySavedPreferences(serverId: '1');
  });

  test('saved selections stay on their original server', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..applySavedPreferences(
        serverId: '1',
        profileId: '12',
        rootFolderId: '102',
      )
      ..setServers([_server(id: 1)]);
    expect(controller.selectedServerId, 1);
    expect(controller.selectedProfileId, 12);
    expect(controller.selectedRootFolderId, 102);
    expect(controller.submission?.serverId, 1);
    expect(controller.submission?.profileId, 12);
    expect(controller.submission?.rootFolder, '/alternate');
    controller.dispose();
  });

  test('missing saved server cannot leak colliding profile/root IDs', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..applySavedPreferences(
        serverId: '999',
        profileId: '12',
        rootFolderId: '102',
      )
      ..setServers([_server(id: 1, isDefault: true)]);
    expect(controller.effectiveServerId, 1);
    expect(controller.effectiveProfileId, 11);
    expect(controller.effectiveRootFolderPath, '/tv');
    controller.dispose();
  });

  test('orphan profile/root preferences without a saved server use defaults', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..applySavedPreferences(profileId: '12', rootFolderId: '102')
      ..setServers([_server(id: 1)]);
    expect(controller.effectiveServerId, 1);
    expect(controller.effectiveProfileId, 11);
    expect(controller.effectiveRootFolderPath, '/tv');
    controller.dispose();
  });

  test('removed server clears selections even when the new IDs collide', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..setServers([_server(id: 1)]);
    controller.onProfileChanged(12);
    controller.onRootFolderChanged(102);
    controller.setServers([_server(id: 2)]);
    expect(controller.effectiveServerId, 2);
    expect(controller.effectiveProfileId, 11);
    expect(controller.effectiveRootFolderPath, '/tv');
    controller.dispose();
  });

  test('changing server validates and resets dependent choices', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..setServers([_server(id: 1), _server(id: 2)]);
    controller.onProfileChanged(12);
    controller.onRootFolderChanged(102);
    controller.onServerChanged(999);
    expect(controller.effectiveServerId, 1);
    controller.onServerChanged(2);
    expect(controller.effectiveServerId, 2);
    expect(controller.effectiveProfileId, 11);
    expect(controller.effectiveRootFolderPath, '/tv');
    controller.onProfileChanged(999);
    controller.onRootFolderChanged(999);
    expect(controller.submission?.profileId, 11);
    expect(controller.submission?.rootFolder, '/tv');
    controller.dispose();
  });

  test('HD and 4K never select servers belonging to the other track', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..setServers([
        _server(id: 1, isDefault: true),
        _server(id: 2, is4k: true),
      ]);
    expect(controller.servers?.map((s) => s.server.id), [1]);
    controller.onServerChanged(2); // Ineligible server must be ignored.
    expect(controller.effectiveServerId, 1);

    controller.applySavedPreferences(
      serverId: '2',
      is4k: true,
    );
    expect(controller.servers?.map((s) => s.server.id), [2]);
    expect(controller.effectiveServerId, 2);
    expect(controller.submission?.serverId, 2);

    controller.setServers([_server(id: 1)]);
    expect(controller.servers, isEmpty);
    expect(controller.effectiveServerId, isNull);
    expect(controller.submission?.serverId, isNull);
    expect(controller.submission?.profileId, isNull);
    expect(controller.submission?.rootFolder, isNull);
    controller.dispose();
  });

  test('4K switch honors distinct saved profile/root defaults', () {
    final controller = SeerrAdvancedRequestController(isTv: false)
      ..setServers([
        _server(id: 1),
        _server(id: 2, is4k: true),
      ]);
    controller.onProfileChanged(12);
    controller.onRootFolderChanged(102);
    controller.applySavedPreferences(
      serverId: '2',
      profileId: '12',
      rootFolderId: '102',
      is4k: true,
    );
    expect(controller.selectedServerId, 2);
    expect(controller.selectedProfileId, 12);
    expect(controller.selectedRootFolderId, 102);
    expect(controller.submission?.serverId, 2);
    controller.dispose();
  });

  test('anime profile/directory choices and missing configuration defaults', () {
    final controller = SeerrAdvancedRequestController(isTv: true, isAnime: true)
      ..setServers([
        _server(
          id: 1,
          animeProfileId: 12,
          animeDirectory: '/alternate',
        ),
      ]);
    expect(controller.effectiveProfileId, 12);
    expect(controller.effectiveRootFolderPath, '/alternate');
    controller.setServers([]);
    expect(controller.submission?.serverId, isNull);
    expect(controller.submission?.rootFolder, isNull);
    controller.dispose();
  });

  test('unusable root folder prevents a partially specified submission', () {
    final controller = SeerrAdvancedRequestController(isTv: true)
      ..setServers([
        _server(
          id: 1,
          folders: const [SeerrRootFolder(id: 101, path: ' ')],
        ),
      ]);
    expect(controller.submission, isNull);
    controller.dispose();
  });

  test('one offline backend does not suppress another configured backend',
      () async {
    GetIt.instance.registerSingleton<SeerrRepository>(_PartialServerRepository());
    final controller = SeerrAdvancedRequestController(isTv: true);
    await controller.load();
    expect(controller.loading, isFalse);
    expect(controller.servers?.map((s) => s.server.id), [2]);
    expect(controller.submission?.serverId, 2);
    controller.dispose();
  });

  test('loading after dispose does not start a repository request', () async {
    final controller = SeerrAdvancedRequestController(isTv: true);
    controller.dispose();
    await controller.load();
    expect(controller.loading, isFalse);
  });
}
