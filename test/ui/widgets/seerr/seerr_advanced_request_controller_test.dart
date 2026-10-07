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

  test('loading after dispose does not start a repository request', () async {
    final controller = SeerrAdvancedRequestController(isTv: true);
    controller.dispose();
    await controller.load();
    expect(controller.loading, isFalse);
  });
}
