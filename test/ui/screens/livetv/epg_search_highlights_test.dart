import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:moonfin/ui/screens/livetv/epg/epg_genre.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_channel_cell.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_hero_preview.dart';
import 'package:moonfin/ui/screens/livetv/epg/widgets/epg_program_cell.dart';

void main() {
  setUp(() => ThemeRegistry.setActiveById(ThemeRegistry.moonfinId));

  testWidgets('calendar only appears for a future-only channel match', (
    tester,
  ) async {
    Future<void> show({required bool future}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 230,
            height: 76,
            child: EpgChannelCell(
              logoUrl: null,
              name: 'TSN',
              number: '20',
              focused: true,
              apple: false,
              hasFutureMatch: future,
            ),
          ),
        ),
      ));
    }

    await show(future: true);
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
    expect(find.text('TSN'), findsOneWidget);

    await show(future: false);
    expect(find.byIcon(Icons.calendar_today_outlined), findsNothing);
    expect(find.text('TSN'), findsOneWidget);
  });

  testWidgets('focused match retains stronger theme focus border', (
    tester,
  ) async {
    Future<double> borderWidth({required bool focused}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 80,
            child: EpgProgramCell(
              title: 'Soccer Highlights',
              genre: const EpgGenre('Sports', Color(0xFF2E8B57)),
              isLive: false,
              progress: 0,
              hasTimer: false,
              focused: focused,
              searchMatch: true,
              apple: false,
            ),
          ),
        ),
      ));
      final decorated = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(EpgProgramCell),
          matching: find.byType(Container),
        ),
      ).firstWhere((container) {
        final decoration = container.foregroundDecoration;
        return decoration is BoxDecoration && decoration.border != null;
      });
      final border =
          (decorated.foregroundDecoration! as BoxDecoration).border! as Border;
      expect(border.top.color,
          focused ? AppColorScheme.accent :
          AppColorScheme.accent.withValues(alpha: 0.45));
      return border.top.width;
    }

    expect(await borderWidth(focused: false), 1);
    expect(await borderWidth(focused: true), 2);
  });

  testWidgets('hero shows the search match instead of the synopsis', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EpgHeroPreview(
          title: 'TSN',
          programTitle: 'SportsCentre',
          timeLabel: '7:00 – 8:00 PM',
          genreLabel: 'Sports',
          synopsis: 'Original SportsCentre description',
          searchMatchTitle: 'Soccer: Portugal vs USA',
          searchMatchTime: 'Tomorrow · 8:00 PM',
          isLive: true,
          apple: false,
          compact: true,
        ),
      ),
    ));
    expect(find.text('SportsCentre'), findsOneWidget);
    expect(find.text('Soccer: Portugal vs USA'), findsOneWidget);
    expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
    expect(find.text('Original SportsCentre description'), findsNothing);
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
