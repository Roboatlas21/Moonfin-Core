import '../../repositories/seerr_repository.dart';
import 'seerr_api_models.dart';

class SeerrRequestDefaults {
  const SeerrRequestDefaults({
    this.serverId,
    this.profileId,
    this.rootFolderId,
  });

  final String? serverId;
  final String? profileId;
  final String? rootFolderId;

  int? get parsedServerId => int.tryParse(serverId ?? '');
  int? get parsedProfileId => int.tryParse(profileId ?? '');
  int? get parsedRootFolderId => int.tryParse(rootFolderId ?? '');
}

class SeerrRequestSubmissionOptions {
  const SeerrRequestSubmissionOptions({
    this.serverId,
    this.profileId,
    this.rootFolder,
  });

  final int? serverId;
  final int? profileId;
  final String? rootFolder;
}

/// Platform-neutral request-option state shared by Flutter and native tvOS.
///
/// It owns server/profile/root-folder defaults and validation. UI layers only
/// render the choices and feed selected ids back here; submission always uses
/// the validated effective values exposed by [submission].
class SeerrRequestOptions {
  SeerrRequestOptions({
    required this.isTv,
    this.isAnime = false,
    this.is4k = false,
  });

  final bool isTv;
  final bool isAnime;
  bool is4k;

  List<SeerrServiceServerDetails> servers = const [];
  bool loaded = false;

  int? selectedServerId;
  int? selectedProfileId;
  int? selectedRootFolderId;

  SeerrRequestDefaults _defaults = const SeerrRequestDefaults();

  Future<void> load(SeerrRepository repository) async {
    final summaries = isTv
        ? await repository.getSonarrServers()
        : await repository.getRadarrServers();
    final details = await Future.wait(
      summaries.map(
        (server) => isTv
            ? repository.getSonarrServerDetails(server.id)
            : repository.getRadarrServerDetails(server.id),
      ),
    );
    setServers(details);
  }

  void setServers(List<SeerrServiceServerDetails> value) {
    servers = List.unmodifiable(value);
    loaded = true;
    _normalizeSelection();
  }

  void applyDefaults(
    SeerrRequestDefaults defaults, {
    bool resetSelection = false,
    bool? is4k,
  }) {
    if (is4k != null) this.is4k = is4k;
    _defaults = defaults;
    if (resetSelection) {
      selectedServerId = null;
      selectedProfileId = null;
      selectedRootFolderId = null;
    }
    _normalizeSelection();
  }

  SeerrServiceServerDetails? get activeServer {
    if (servers.isEmpty) return null;
    final selected = selectedServerId;
    if (selected != null) {
      for (final server in servers) {
        if (server.server.id == selected) return server;
      }
    }
    return _defaultServer;
  }

  SeerrServiceServerDetails? get _defaultServer {
    if (servers.isEmpty) return null;
    for (final server in servers) {
      if (server.server.is4k == is4k && server.server.isDefault) return server;
    }
    for (final server in servers) {
      if (server.server.is4k == is4k) return server;
    }
    return servers.first;
  }

  int? defaultProfileIdFor(SeerrServiceServerDetails server) {
    final preferred = isAnime && server.server.activeAnimeProfileId != null
        ? server.server.activeAnimeProfileId
        : server.server.activeProfileId;
    if (server.profiles.isEmpty) return null;
    return server.profiles.any((profile) => profile.id == preferred)
        ? preferred
        : server.profiles.first.id;
  }

  int? defaultRootFolderIdFor(SeerrServiceServerDetails server) {
    final animeDirectory = server.server.activeAnimeDirectory;
    final directory = isAnime &&
            animeDirectory != null &&
            animeDirectory.isNotEmpty
        ? animeDirectory
        : server.server.activeDirectory;
    if (directory.isNotEmpty) {
      for (final folder in server.rootFolders) {
        if (folder.path == directory) return folder.id;
      }
    }
    return server.rootFolders.isEmpty ? null : server.rootFolders.first.id;
  }

  int? get effectiveServerId => activeServer?.server.id;

  int? get effectiveProfileId {
    final server = activeServer;
    if (server == null) return null;
    final selected = selectedProfileId;
    if (selected != null &&
        server.profiles.any((profile) => profile.id == selected)) {
      return selected;
    }
    return defaultProfileIdFor(server);
  }

  int? get effectiveRootFolderId {
    final server = activeServer;
    if (server == null) return null;
    final selected = selectedRootFolderId;
    if (selected != null &&
        server.rootFolders.any((folder) => folder.id == selected)) {
      return selected;
    }
    return defaultRootFolderIdFor(server);
  }

  String? get effectiveRootFolderPath {
    final server = activeServer;
    final id = effectiveRootFolderId;
    if (server == null || id == null) return null;
    for (final folder in server.rootFolders) {
      if (folder.id == id) return folder.path;
    }
    return null;
  }

  bool selectServer(int? id) {
    if (id != null && !servers.any((server) => server.server.id == id)) {
      return false;
    }
    selectedServerId = id;
    selectedProfileId = null;
    selectedRootFolderId = null;
    _applyServerDefaults();
    return true;
  }

  bool selectProfile(int? id) {
    final server = activeServer;
    if (id != null &&
        (server == null ||
            !server.profiles.any((profile) => profile.id == id))) {
      return false;
    }
    selectedProfileId = id;
    return true;
  }

  bool selectRootFolder(int? id) {
    final server = activeServer;
    if (id != null &&
        (server == null ||
            !server.rootFolders.any((folder) => folder.id == id))) {
      return false;
    }
    selectedRootFolderId = id;
    return true;
  }

  bool get isValid {
    final server = activeServer;
    if (servers.isEmpty) {
      return selectedServerId == null &&
          selectedProfileId == null &&
          selectedRootFolderId == null;
    }
    if (server == null || effectiveServerId == null) return false;
    if (selectedProfileId != null &&
        !server.profiles.any((profile) => profile.id == selectedProfileId)) {
      return false;
    }
    if (selectedRootFolderId != null &&
        !server.rootFolders.any((folder) => folder.id == selectedRootFolderId)) {
      return false;
    }
    return true;
  }

  SeerrRequestSubmissionOptions? get submission => isValid
      ? SeerrRequestSubmissionOptions(
          serverId: effectiveServerId,
          profileId: effectiveProfileId,
          rootFolder: effectiveRootFolderPath,
        )
      : null;

  void _normalizeSelection() {
    if (servers.isEmpty) {
      selectedServerId = null;
      selectedProfileId = null;
      selectedRootFolderId = null;
      return;
    }

    if (selectedServerId == null ||
        !servers.any((server) => server.server.id == selectedServerId)) {
      final saved = _defaults.parsedServerId;
      selectedServerId = saved != null &&
              servers.any((server) => server.server.id == saved)
          ? saved
          : _defaultServer?.server.id;
    }

    final server = activeServer;
    if (server == null) return;

    if (selectedProfileId == null ||
        !server.profiles.any((profile) => profile.id == selectedProfileId)) {
      final saved = _defaults.parsedProfileId;
      selectedProfileId = saved != null &&
              server.profiles.any((profile) => profile.id == saved)
          ? saved
          : defaultProfileIdFor(server);
    }

    if (selectedRootFolderId == null ||
        !server.rootFolders.any((folder) => folder.id == selectedRootFolderId)) {
      final saved = _defaults.parsedRootFolderId;
      selectedRootFolderId = saved != null &&
              server.rootFolders.any((folder) => folder.id == saved)
          ? saved
          : defaultRootFolderIdFor(server);
    }
  }

  void _applyServerDefaults() {
    final server = activeServer;
    if (server == null) return;
    selectedServerId ??= server.server.id;
    selectedProfileId ??= defaultProfileIdFor(server);
    selectedRootFolderId ??= defaultRootFolderIdFor(server);
  }
}
