import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../../data/viewmodels/live_tv_guide_view_model.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../util/focus/dpad_keys.dart';
import '../../../../util/platform_detection.dart';
import '../../../widgets/local_search_field.dart';
import '../../../widgets/overlay_sheet.dart';

export '../../../../data/viewmodels/live_tv_guide_view_model.dart'
    show GuideFilterChoice;

typedef _RowId = GuideFilterChoice;


class GuideFilterPicker extends StatefulWidget {
  const GuideFilterPicker({
    super.key,
    required this.vm,
    required this.includeCategories,
    required this.filterLabel,
    required this.sidePanel,
    this.onRightClose,
  });

  final LiveTvGuideViewModel vm;
  final bool includeCategories;
  final String Function(GuideFilter) filterLabel;
  final bool sidePanel;
  final VoidCallback? onRightClose;

  @override
  State<GuideFilterPicker> createState() => _GuideFilterPickerState();
}

typedef _Row = ({String label, _RowId? id, IconData? icon, int? count});

class _GuideFilterPickerState extends State<GuideFilterPicker> {
  final _searchFieldKey = GlobalKey();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _nodes = <_RowId, FocusNode>{};
  final _focusedRow = ValueNotifier<_RowId?>(null);
  ScrollController? _scroll;
  String _query = '';
  List<_Row> _visibleRows = const [];

  GuideFilterChoice get _selected =>
      (widget.vm.filter, widget.vm.selectedGroup);

  @override
  void initState() {
    super.initState();
    if (!PlatformDetection.isTV || !widget.sidePanel) return;
    // The TV route observer can give Search focus before the list lays out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.isCurrentOf(context) != true) return;
      final active = _visibleRows
          .where((row) => row.id == _selected)
          .firstOrNull
          ?.id;
      if (active != null) _focusRow(active);
    });
  }

  void _focusRow(_RowId id) {
    final index = _visibleRows.indexWhere((row) => row.id == id);
    final scroll = _scroll;
    if (index < 0 || scroll == null || !scroll.hasClients) return;
    final height = _rowHeight;
    final top = index * height;
    final position = scroll.position;
    final visibleRoom = (position.viewportDimension - height).clamp(
      0.0,
      double.infinity,
    );
    final offset = position.pixels
        .clamp(top - visibleRoom, top)
        .clamp(0.0, position.maxScrollExtent);
    if (position.pixels != offset) scroll.jumpTo(offset);
    // Lazy rows beyond the old viewport attach during the next layout.
    final node = _nodes.putIfAbsent(id, FocusNode.new);
    node.requestFocus();
  }

  double get _rowHeight => MediaQuery.textScalerOf(context).scale(20) + 36;

  List<_Row> _rows(AppLocalizations l10n) {
    final rows = <_Row>[];
    void section(String label) =>
        rows.add((label: label, id: null, icon: null, count: null));

    void add(GuideFilterChoice choice) {
      final (filter, group) = choice;
      final label = group ??
          (filter == GuideFilter.all ? l10n.guideAllChannels : widget.filterLabel(filter));
      if (!label.toLowerCase().contains(_query)) return;
      rows.add((
        id: choice,
        label: label,
        icon: group != null
            ? Icons.folder_outlined
            : switch (filter) {
                GuideFilter.movies => Icons.movie_outlined,
                GuideFilter.series => Icons.tv,
                GuideFilter.sports => Icons.sports_soccer,
                GuideFilter.news => Icons.newspaper,
                GuideFilter.kids => Icons.child_care,
                GuideFilter.premiere => Icons.new_releases_outlined,
                GuideFilter.favorites => Icons.favorite_border,
                GuideFilter.all => Icons.live_tv,
              },
        count: group == null ? null : widget.vm.channelCountForGroup(group),
      ));
    }

    add((GuideFilter.all, null));
    add((GuideFilter.favorites, null));
    void addSection(String title, Iterable<GuideFilterChoice> choices) {
      final start = rows.length;
      section(title);
      for (final choice in choices) {
        add(choice);
      }
      if (rows.length == start + 1) rows.removeLast();
    }

    addSection(
      l10n.liveTvChannelGroups,
      widget.vm.availableGroups.map((g) => (GuideFilter.all, g)),
    );
    if (widget.includeCategories) {
      addSection(
        l10n.liveTvProgrammeCategories,
        widget.vm.availableProgrammeCategories.map((f) => (f, null)),
      );
    }
    return rows;
  }

  Widget _remoteHint(String key, String action) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          color: AppColorScheme.onSurface.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(key),
        ),
      ),
      const SizedBox(width: 6),
      Text(action),
    ],
  );

  @override
  void dispose() {
    _scroll?.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _focusedRow.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final compact =
        !widget.sidePanel &&
        keyboard > 0 &&
        MediaQuery.sizeOf(context).height - keyboard < 240;
    final search = LocalSearchField(
      key: _searchFieldKey,
      controller: _search,
      focusNode: _searchFocus,
      hint: widget.includeCategories
          ? l10n.guideSearchGroupsAndCategories
          : l10n.guideSearchGroups,
      onChanged: (value) {
        setState(() => _query = value.trim().toLowerCase());
        if (_scroll?.hasClients == true) _scroll!.jumpTo(0);
      },
    );
    final closeOnBack = createDialogBackCloseHandler(context);
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        final id = _focusedRow.value;
        if (PlatformDetection.isTV &&
            id != null &&
            _nodes[id]?.hasFocus == true) {
          if (isActivateKey(event)) {
            Navigator.of(context).pop(id);
            return KeyEventResult.handled;
          }
          if (event.isActionable && event.logicalKey.isUpKey) {
            final previous = _visibleRows
                .takeWhile((row) => row.id != id)
                .map((row) => row.id)
                .nonNulls
                .lastOrNull;
            if (previous == null) {
              _searchFocus.requestFocus();
            } else {
              _focusRow(previous);
            }
            return KeyEventResult.handled;
          }
        }
        if (event.isActionable &&
            event.logicalKey.isBackKey &&
            !(event.logicalKey == LogicalKeyboardKey.backspace &&
                _searchFocus.hasFocus)) {
          if (event is KeyDownEvent && !DialogBackSuppressor.dismissKeyboardFor(event)) {
            closeOnBack();
          }
          return KeyEventResult.handled;
        }
        if (widget.sidePanel &&
            (PlatformDetection.isTV || !_searchFocus.hasFocus) &&
            event is KeyDownEvent &&
            event.logicalKey.isRightKey) {
          widget.onRightClose?.call();
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: AppColorScheme.surface,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              8,
              12,
              (compact ? 0 : 8) + keyboard,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (!widget.sidePanel) const BackButton(),
                    Expanded(
                      child: compact
                          ? search
                          : Text(
                              l10n.filters,
                              style: Theme.of(context).textTheme.titleLarge,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                  ],
                ),
                if (!compact) ...[
                  const SizedBox(height: 8),
                  search,
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.vm,
                    builder: (context, _) {
                      final rows = _visibleRows = _rows(l10n);
                      final rowHeight = _rowHeight;
                      final indices = {
                        for (var i = 0; i < rows.length; i++)
                          if (rows[i].id != null) rows[i].id!: i,
                      };
                      final selected = rows.indexWhere(
                        (row) => row.id == _selected,
                      );
                      _scroll ??= ScrollController(
                        initialScrollOffset: selected > 2
                            ? (selected - 2) * rowHeight
                            : 0,
                      );
                      final list = ListView.builder(
                        controller: _scroll,
                        findChildIndexCallback: (key) =>
                            key is ValueKey<_RowId> ? indices[key.value] : null,
                        itemCount: rows.length,
                        itemExtent: rowHeight,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final id = row.id;
                          if (id == null) {
                            return Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                row.label,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            );
                          }
                          final choice = id;
                          final active = choice == _selected;
                          return ListTile(
                            key: ValueKey(id),
                            focusNode: _nodes.putIfAbsent(id, FocusNode.new),
                            onFocusChange: (focused) {
                              if (focused) {
                                _focusedRow.value = id;
                              } else if (_focusedRow.value == id) {
                                _focusedRow.value = null;
                              }
                            },
                            autofocus:
                                widget.sidePanel &&
                                index == selected &&
                                _query.isEmpty,
                            selected: active,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            focusColor: AppColorScheme.accent.withValues(
                              alpha: 0.32,
                            ),
                            selectedColor: widget.sidePanel
                                ? AppColorScheme.accent
                                : Colors.black,
                            selectedTileColor: widget.sidePanel
                                ? null
                                : AppColorScheme.accent,
                            leading: Icon(
                              row.icon,
                              color: choice.$1 == GuideFilter.favorites
                                  ? AppColorScheme.onSurface
                                  : null,
                            ),
                            title: Text(
                              row.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (row.count != null) Text('${row.count}'),
                                if (active) const Icon(Icons.check),
                              ],
                            ),
                            onTap: () => Navigator.of(context).pop(choice),
                          );
                        },
                      );
                      // Keep the list attached so query edits can reset its offset.
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          list,
                          if (rows.isEmpty) Center(child: Text(l10n.noResults)),
                        ],
                      );
                    },
                  ),
                ),
                if (PlatformDetection.isTV)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Wrap(
                      spacing: 16,
                      children: [
                        _remoteHint(l10n.ok, l10n.select),
                        if (widget.sidePanel) _remoteHint('→', l10n.close),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
