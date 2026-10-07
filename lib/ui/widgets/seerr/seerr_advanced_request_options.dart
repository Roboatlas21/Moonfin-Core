import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/repositories/seerr_repository.dart';
import '../../../data/services/seerr/seerr_api_models.dart';
import '../../../l10n/app_localizations.dart';
import '../focus/focusable_wrapper.dart';
import 'seerr_tv_controls.dart';

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

/// Radarr/Sonarr selections for regular and collection requests. Cinema Mode
/// uses Seerr defaults and never loads these advanced choices.
class SeerrAdvancedRequestController extends ChangeNotifier {
  SeerrAdvancedRequestController({
    required this.isTv,
    this.isAnime = false,
    this.is4k = false,
  });

  final bool isTv;
  final bool isAnime;
  bool is4k;
  bool loading = false;
  bool _disposed = false;

  List<SeerrServiceServerDetails>? _servers;
  List<SeerrServiceServerDetails>? get servers => _servers == null
      ? null
      : [for (final s in _servers!) if (s.server.is4k == is4k) s];

  int? selectedServerId;
  int? selectedProfileId;
  int? selectedRootFolderId;
  String? _savedServerId;
  String? _savedProfileId;
  String? _savedRootFolderId;

  static int? _id(String? value) => int.tryParse(value ?? '');

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (_disposed) return;
    loading = true;
    notifyListeners();
    try {
      final repo = await GetIt.instance.getAsync<SeerrRepository>();
      if (_disposed) return;
      final summaries =
          isTv ? await repo.getSonarrServers() : await repo.getRadarrServers();
      // A failing Sonarr/Radarr instance must not hide other usable instances.
      final details = await Future.wait(summaries.map((s) async {
        try {
          return isTv
              ? await repo.getSonarrServerDetails(s.id)
              : await repo.getRadarrServerDetails(s.id);
        } catch (_) {
          return null;
        }
      }));
      if (_disposed) return;
      _servers = List.unmodifiable(details.whereType<SeerrServiceServerDetails>());
      _normalize();
    } catch (_) {
      if (!_disposed) {
        _servers = const [];
        _clearSelection();
      }
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Also lets selection rules be exercised without network or widget setup.
  void setServers(List<SeerrServiceServerDetails> value) {
    if (_disposed) return;
    _servers = List.unmodifiable(value);
    _normalize();
    notifyListeners();
  }

  void applySavedPreferences({
    String? serverId,
    String? profileId,
    String? rootFolderId,
    bool resetSelection = false,
    bool? is4k,
  }) {
    if (_disposed) return;
    final trackChanged = is4k != null && is4k != this.is4k;
    if (is4k != null) this.is4k = is4k;
    _savedServerId = serverId;
    _savedProfileId = profileId;
    _savedRootFolderId = rootFolderId;
    if (resetSelection || trackChanged) _clearSelection();
    _normalize();
    notifyListeners();
  }

  void _clearSelection() {
    selectedServerId = null;
    selectedProfileId = null;
    selectedRootFolderId = null;
  }

  SeerrServiceServerDetails? get activeServer {
    final eligible = servers ?? const <SeerrServiceServerDetails>[];
    return eligible.where((s) => s.server.id == selectedServerId).firstOrNull ??
        eligible.where((s) => s.server.isDefault).firstOrNull ??
        eligible.firstOrNull;
  }

  int? _defaultProfile(SeerrServiceServerDetails server) {
    if (server.profiles.isEmpty) return null;
    final desired = isAnime
        ? server.server.activeAnimeProfileId ?? server.server.activeProfileId
        : server.server.activeProfileId;
    return server.profiles.any((p) => p.id == desired)
        ? desired
        : server.profiles.first.id;
  }

  int? _defaultRoot(SeerrServiceServerDetails server) {
    final directory = isAnime &&
            (server.server.activeAnimeDirectory?.isNotEmpty ?? false)
        ? server.server.activeAnimeDirectory!
        : server.server.activeDirectory;
    return server.rootFolders.where((f) => f.path == directory).firstOrNull?.id ??
        server.rootFolders.firstOrNull?.id;
  }

  void _normalize() {
    final eligible = servers ?? const <SeerrServiceServerDetails>[];
    if (eligible.isEmpty) {
      _clearSelection();
      return;
    }
    final previousServerId = selectedServerId;
    if (!eligible.any((s) => s.server.id == selectedServerId)) {
      final saved = _id(_savedServerId);
      selectedServerId = eligible.any((s) => s.server.id == saved)
          ? saved
          : eligible.where((s) => s.server.isDefault).firstOrNull?.server.id ??
              eligible.first.server.id;
    }
    if (selectedServerId != previousServerId) {
      selectedProfileId = null;
      selectedRootFolderId = null;
    }
    final server = activeServer!;
    // Profiles and roots are server-specific; matching numeric IDs alone
    // are not enough to carry a saved selection to a replacement server.
    final useSaved = _id(_savedServerId) == server.server.id;
    if (!server.profiles.any((p) => p.id == selectedProfileId)) {
      final saved = _id(_savedProfileId);
      selectedProfileId = useSaved &&
              server.profiles.any((p) => p.id == saved)
          ? saved
          : _defaultProfile(server);
    }
    if (!server.rootFolders.any((f) => f.id == selectedRootFolderId)) {
      final saved = _id(_savedRootFolderId);
      selectedRootFolderId = useSaved &&
              server.rootFolders.any((f) => f.id == saved)
          ? saved
          : _defaultRoot(server);
    }
  }

  int? get effectiveServerId => activeServer?.server.id;

  int? get effectiveProfileId {
    final server = activeServer;
    if (server == null) return null;
    return server.profiles.any((p) => p.id == selectedProfileId)
        ? selectedProfileId
        : _defaultProfile(server);
  }

  String? get effectiveRootFolderPath {
    final server = activeServer;
    if (server == null) return null;
    final root = server.rootFolders
        .where((f) => f.id == selectedRootFolderId)
        .firstOrNull;
    return root?.path;
  }

  /// Validate overrides together. Missing configuration uses Seerr's own
  /// defaults; malformed choices never get submitted as partial overrides.
  SeerrRequestSubmissionOptions? get submission {
    if (loading) return null;
    final server = activeServer;
    if (server == null) return const SeerrRequestSubmissionOptions();
    final profileId = effectiveProfileId;
    final rootFolder = effectiveRootFolderPath;
    if (server.profiles.isNotEmpty && profileId == null) return null;
    if (server.rootFolders.isNotEmpty &&
        (rootFolder == null || rootFolder.trim().isEmpty)) {
      return null;
    }
    return SeerrRequestSubmissionOptions(
      serverId: server.server.id,
      profileId: profileId,
      rootFolder: rootFolder,
    );
  }

  void onServerChanged(int? value) {
    if (_disposed) return;
    final eligible = servers ?? const <SeerrServiceServerDetails>[];
    if (value != null && !eligible.any((s) => s.server.id == value)) return;
    selectedServerId = value;
    selectedProfileId = null;
    selectedRootFolderId = null;
    _normalize();
    notifyListeners();
  }

  void onProfileChanged(int? value) {
    if (_disposed) return;
    final server = activeServer;
    if (server == null ||
        (value != null && !server.profiles.any((p) => p.id == value))) return;
    selectedProfileId = value ?? _defaultProfile(server);
    notifyListeners();
  }

  void onRootFolderChanged(int? value) {
    if (_disposed) return;
    final server = activeServer;
    if (server == null ||
        (value != null && !server.rootFolders.any((f) => f.id == value))) {
      return;
    }
    selectedRootFolderId = value ?? _defaultRoot(server);
    notifyListeners();
  }
}

/// The advanced options section with server, quality profile, and root folder
/// pickers, driven by a [SeerrAdvancedRequestController]. Uses d-pad friendly
/// rows and list pickers instead of Material dropdowns so it works on TV.
class SeerrAdvancedRequestOptions extends StatefulWidget {
  final SeerrAdvancedRequestController controller;

  const SeerrAdvancedRequestOptions({super.key, required this.controller});

  @override
  State<SeerrAdvancedRequestOptions> createState() =>
      _SeerrAdvancedRequestOptionsState();
}

class _SeerrAdvancedRequestOptionsState
    extends State<SeerrAdvancedRequestOptions> {
  bool _expanded = false;

  SeerrAdvancedRequestController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final headerColor = AppColorScheme.onSurface.withValues(alpha: 0.7);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FocusableWrapper(
            onSelect: () => setState(() => _expanded = !_expanded),
            borderRadius: 8,
            useBackgroundFocus: true,
            disableScale: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.advancedOptions,
                      style: TextStyle(color: headerColor),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: headerColor,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            if (controller.loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (controller.servers?.isNotEmpty == true) ...[
              _buildPickerRow<SeerrServiceServerDetails>(
                label: l10n.server,
                items: controller.servers ?? const [],
                idOf: (s) => s.server.id,
                labelOf: _serverLabel,
                selectedId: controller.selectedServerId,
                onChanged: controller.onServerChanged,
              ),
              const SizedBox(height: 12),
              _buildPickerRow<SeerrQualityProfile>(
                label: l10n.qualityProfile,
                items: controller.activeServer?.profiles ?? const [],
                idOf: (p) => p.id,
                labelOf: (p) => p.name,
                selectedId: controller.selectedProfileId,
                onChanged: controller.onProfileChanged,
              ),
              const SizedBox(height: 12),
              _buildPickerRow<SeerrRootFolder>(
                label: l10n.rootFolder,
                items: controller.activeServer?.rootFolders ?? const [],
                idOf: (f) => f.id,
                labelOf: (f) => f.path,
                selectedId: controller.selectedRootFolderId,
                onChanged: controller.onRootFolderChanged,
              ),
            ] else
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  l10n.noServiceServersConfigured,
                  style: TextStyle(
                    color: AppColorScheme.onSurface.withValues(alpha: 0.54),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _serverLabel(SeerrServiceServerDetails s) =>
      '${s.server.name}${s.server.is4k ? " (4K)" : ""}';

  Widget _buildPickerRow<T>({
    required String label,
    required List<T> items,
    required int Function(T) idOf,
    required String Function(T) labelOf,
    required int? selectedId,
    required ValueChanged<int?> onChanged,
  }) {
    final resolvedId = selectedId ?? (items.isEmpty ? null : idOf(items.first));
    final selected = items.where((e) => idOf(e) == resolvedId).firstOrNull ??
        items.firstOrNull;
    return SeerrSelectorRow(
      label: label,
      value: selected == null ? '' : labelOf(selected),
      onTap: () async {
        final ids = [for (final e in items) idOf(e)];
        final current = ids.indexOf(resolvedId ?? -1);
        final picked = await showSeerrOptionPicker(
          context,
          title: label,
          labels: [for (final e in items) labelOf(e)],
          selectedIndex: current < 0 ? 0 : current,
        );
        if (picked != null) onChanged(ids[picked]);
      },
    );
  }
}
