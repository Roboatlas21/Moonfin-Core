import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/repositories/seerr_repository.dart';
import '../../../data/services/seerr/seerr_api_models.dart';
import '../../../data/services/seerr/seerr_request_options.dart';
import '../../../l10n/app_localizations.dart';
import '../focus/focusable_wrapper.dart';
import 'seerr_tv_controls.dart';

/// Flutter notifier around the platform-neutral [SeerrRequestOptions] model.
class SeerrAdvancedRequestController extends ChangeNotifier {
  SeerrAdvancedRequestController({
    required bool isTv,
    bool isAnime = false,
    bool is4k = false,
  }) : _options = SeerrRequestOptions(
         isTv: isTv,
         isAnime: isAnime,
         is4k: is4k,
       );

  final SeerrRequestOptions _options;
  bool loading = false;
  bool _disposed = false;

  bool get isTv => _options.isTv;
  bool get isAnime => _options.isAnime;
  bool get is4k => _options.is4k;
  List<SeerrServiceServerDetails>? get servers =>
      _options.loaded ? _options.eligibleServers : null;
  SeerrRequestSubmissionOptions? get submission => _options.submission;
  int? get selectedServerId => _options.selectedServerId;
  int? get selectedProfileId => _options.selectedProfileId;
  int? get selectedRootFolderId => _options.selectedRootFolderId;
  SeerrServiceServerDetails? get activeServer => _options.activeServer;
  int? get effectiveServerId => _options.effectiveServerId;
  int? get effectiveProfileId => _options.effectiveProfileId;
  String? get effectiveRootFolderPath => _options.effectiveRootFolderPath;

  Future<void> load() async {
    if (_disposed) return;
    loading = true;
    notifyListeners();
    try {
      final repo = await GetIt.instance.getAsync<SeerrRepository>();
      if (_disposed) return;
      await _options.load(repo);
    } catch (_) {
      // Advanced overrides are optional; the request can use Seerr defaults.
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void applySavedPreferences({
    String? serverId,
    String? profileId,
    String? rootFolderId,
    bool resetSelection = false,
    bool? is4k,
  }) {
    if (_disposed) return;
    _options.applyDefaults(
      SeerrRequestDefaults(
        serverId: serverId,
        profileId: profileId,
        rootFolderId: rootFolderId,
      ),
      resetSelection: resetSelection,
      is4k: is4k,
    );
    notifyListeners();
  }

  void onServerChanged(int? value) {
    if (!_disposed && _options.selectServer(value)) notifyListeners();
  }

  void onProfileChanged(int? value) {
    if (!_disposed && _options.selectProfile(value)) notifyListeners();
  }

  void onRootFolderChanged(int? value) {
    if (!_disposed && _options.selectRootFolder(value)) notifyListeners();
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
