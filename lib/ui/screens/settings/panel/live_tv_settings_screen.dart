part of '../settings_side_panel.dart';

class _LiveTvSettingsScreen extends StatelessWidget {
  const _LiveTvSettingsScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: buildSettingsAppBar(context, Text(l10n.liveTV)),
      body: ListView(
        children: [
          adaptiveListSection(
            children: [
              EnumPreferenceTile<LiveTvCategoryDisplay>(
                autofocus: true,
                preference: UserPreferences.liveTvCategoryDisplay,
                title: l10n.liveTvCategoryDisplay,
                icon: Icons.filter_list,
                labelOf: (value) => switch (value) {
                  LiveTvCategoryDisplay.programmes =>
                    l10n.liveTvProgrammeCategories,
                  LiveTvCategoryDisplay.groups => l10n.liveTvChannelGroups,
                  LiveTvCategoryDisplay.both => l10n.settingsBoth,
                },
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.liveTvDirectPlayEnabled,
                title: l10n.settingsLiveTvDirect,
                subtitle: l10n.settingsLiveTvDirectSubtitle,
                icon: Icons.live_tv,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
