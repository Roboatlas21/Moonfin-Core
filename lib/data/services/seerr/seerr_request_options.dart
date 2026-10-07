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

/// The request options are calculated in Dart. Flutter and tvOS are only
/// responsible for presenting choices and returning the user's selection.
enum SeerrRequestOptionsState { loading, ready, defaultsOnly }

class SeerrRequestSelection {
  const SeerrRequestSelection({
    required this.serverId,
    this.profileId,
    this.rootFolderId,
  });

  final int? serverId;
  final int? profileId;
  final int? rootFolderId;
}

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
  SeerrRequestOptionsState state = SeerrRequestOptionsState.defaultsOnly;
  bool get loaded => state != SeerrRequestOptionsState.loading;

  int? _selectedServerId;
  int? _selectedProfileId;
  int? _selectedRootFolderId;

  int? get selectedServerId => _selectedServerId;
  int? get selectedProfileId => _selectedProfileId;
  int? get selectedRootFolderId => _selectedRootFolderId;

  SeerrRequestDefaults _defaults = const SeerrRequestDefaults();

  List<SeerrServiceServerDetails> get eligibleServers => [
    for (final server in servers)
      if (server.server.is4k == is4k) server,
  ];

  bool get usingSeerrDefaults =>
      state == SeerrRequestOptionsState.defaultsOnly ||
      (state == SeerrRequestOptionsState.ready && eligibleServers.isEmpty);

  Future<void> load(SeerrRepository repository) async {
    state = SeerrRequestOptionsState.loading;
    try {
      final summaries = isTv
          ? await repository.getSonarrServers()
          : await repository.getRadarrServers();
      // One broken backend should not hide the other configured backends.
      final details = await Future.wait(
        summaries.map((server) async {
          try {
            return isTv
                ? await repository.getSonarrServerDetails(server.id)
                : await repository.getRadarrServerDetails(server.id);
          } catch (_) {
            return null;
          }
        }),
      );
      final available = details.whereType<SeerrServiceServerDetails>().toList();
      if (available.isEmpty && summaries.isNotEmpty) {
        useSeerrDefaults();
      } else {
        setServers(available);
      }
    } catch (_) {
      useSeerrDefaults();
      rethrow;
    }
  }

  void setServers(List<SeerrServiceServerDetails> value) {
    servers = List.unmodifiable(value);
    state = servers.isEmpty
        ? SeerrRequestOptionsState.defaultsOnly
        : SeerrRequestOptionsState.ready;
    _normalizeSelection();
  }

  /// Only the absence of advanced options may fall back to Seerr-managed
  /// defaults. An invalid *supplied* selection never takes this path.
  void useSeerrDefaults() {
    servers = const [];
    state = SeerrRequestOptionsState.defaultsOnly;
    _clearSelection();
  }

  void applyDefaults(
    SeerrRequestDefaults defaults, {
    bool resetSelection = false,
    bool? is4k,
  }) {
    final trackChanged = is4k != null && is4k != this.is4k;
    if (is4k != null) this.is4k = is4k;
    _defaults = defaults;
    if (resetSelection || trackChanged) _clearSelection();
    _normalizeSelection();
  }

  SeerrServiceServerDetails? get activeServer {
    if (state != SeerrRequestOptionsState.ready) return null;
    for (final server in eligibleServers) {
      if (server.server.id == _selectedServerId) return server;
    }
    return _defaultServer;
  }

  SeerrServiceServerDetails? get _defaultServer {
    final eligible = eligibleServers;
    if (eligible.isEmpty) return null;
    for (final server in eligible) {
      if (server.server.isDefault) return server;
    }
    return eligible.first;
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
    return _selectedProfileId ?? defaultProfileIdFor(server);
  }

  int? get effectiveRootFolderId {
    final server = activeServer;
    if (server == null) return null;
    return _selectedRootFolderId ?? defaultRootFolderIdFor(server);
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
    if (state != SeerrRequestOptionsState.ready ||
        (id != null &&
            !eligibleServers.any((server) => server.server.id == id))) {
      return false;
    }
    _selectedServerId = id ?? _defaultServer?.server.id;
    _selectedProfileId = null;
    _selectedRootFolderId = null;
    _applyServerDefaults();
    return true;
  }

  bool selectProfile(int? id) {
    final server = activeServer;
    if (server == null ||
        (id != null && !server.profiles.any((profile) => profile.id == id))) {
      return false;
    }
    _selectedProfileId = id ?? defaultProfileIdFor(server);
    return true;
  }

  bool selectRootFolder(int? id) {
    final server = activeServer;
    if (server == null ||
        (id != null && !server.rootFolders.any((folder) => folder.id == id))) {
      return false;
    }
    _selectedRootFolderId = id ?? defaultRootFolderIdFor(server);
    return true;
  }

  /// Validate an entire returned native selection without mutating the
  /// current state. Never replace invalid user selections with defaults.
  SeerrRequestSubmissionOptions? resolveForSubmission(
    SeerrRequestSelection selection,
  ) {
    if (state != SeerrRequestOptionsState.ready) return null;
    SeerrServiceServerDetails? server;
    for (final candidate in eligibleServers) {
      if (candidate.server.id == selection.serverId) {
        server = candidate;
        break;
      }
    }
    if (server == null) return null;

    if (server.profiles.isEmpty) {
      if (selection.profileId != null) return null;
    } else if (!server.profiles.any(
      (profile) => profile.id == selection.profileId,
    )) {
      return null;
    }

    SeerrRootFolder? root;
    for (final folder in server.rootFolders) {
      if (folder.id == selection.rootFolderId) {
        root = folder;
        break;
      }
    }
    if (server.rootFolders.isEmpty) {
      if (selection.rootFolderId != null) return null;
    } else if (root == null || root.path.trim().isEmpty) {
      return null;
    }

    return SeerrRequestSubmissionOptions(
      serverId: server.server.id,
      profileId: selection.profileId,
      rootFolder: root?.path,
    );
  }

  bool get isValid => submission != null;

  SeerrRequestSubmissionOptions? get submission {
    if (state == SeerrRequestOptionsState.loading) return null;
    if (usingSeerrDefaults) return const SeerrRequestSubmissionOptions();
    return resolveForSubmission(
      SeerrRequestSelection(
        serverId: _selectedServerId,
        profileId: _selectedProfileId,
        rootFolderId: _selectedRootFolderId,
      ),
    );
  }

  void _clearSelection() {
    _selectedServerId = null;
    _selectedProfileId = null;
    _selectedRootFolderId = null;
  }

  void _normalizeSelection() {
    final eligible = eligibleServers;
    if (state != SeerrRequestOptionsState.ready || eligible.isEmpty) {
      _clearSelection();
      return;
    }

    if (_selectedServerId == null ||
        !eligible.any((server) => server.server.id == _selectedServerId)) {
      final saved = _defaults.parsedServerId;
      _selectedServerId = saved != null &&
              eligible.any((server) => server.server.id == saved)
          ? saved
          : _defaultServer?.server.id;
    }

    final server = activeServer;
    if (server == null) return;

    if (_selectedProfileId == null ||
        !server.profiles.any((profile) => profile.id == _selectedProfileId)) {
      final saved = _defaults.parsedProfileId;
      _selectedProfileId = saved != null &&
              server.profiles.any((profile) => profile.id == saved)
          ? saved
          : defaultProfileIdFor(server);
    }

    if (_selectedRootFolderId == null ||
        !server.rootFolders.any(
          (folder) => folder.id == _selectedRootFolderId,
        )) {
      final saved = _defaults.parsedRootFolderId;
      _selectedRootFolderId = saved != null &&
              server.rootFolders.any((folder) => folder.id == saved)
          ? saved
          : defaultRootFolderIdFor(server);
    }
  }

  void _applyServerDefaults() {
    final server = activeServer;
    if (server == null) return;
    _selectedProfileId = defaultProfileIdFor(server);
    _selectedRootFolderId = defaultRootFolderIdFor(server);
  }
}
