import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/plex_repository.dart';
import 'package:moonfin/data/services/plex_tv_service.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/screens/auth/plex_sign_in_screen.dart';

class _PlexTv extends Mock implements PlexTvService {}

class _Repository extends Mock implements PlexRepository {}

void main() {
  testWidgets(
    'Free TV can reauthorize and open Home without server discovery',
    (tester) async {
      final tv = _PlexTv();
      final repo = _Repository();
      GetIt.instance.registerSingleton<PlexTvService>(tv);
      GetIt.instance.registerSingleton<PlexRepository>(repo);
      addTearDown(() => GetIt.instance.reset());
      var pin = 0;
      when(tv.createPin).thenAnswer(
        (_) async =>
            PlexPin(id: ++pin, code: 'PIN-$pin', expiresAt: DateTime.utc(2100)),
      );
      when(() => tv.checkPin(1)).thenAnswer((_) async => 'expired');
      when(() => tv.checkPin(2)).thenAnswer((_) async => 'approved');
      final discovery = Completer<List<PlexServer>>();
      when(() => repo.loadServers('expired'))
          .thenAnswer((_) => discovery.future);
      when(() => repo.loadServers('approved'))
          .thenThrow(Exception('Server discovery unavailable'));
      final request = RequestOptions(path: 'https://plex.tv/api/v2/user');
      when(() => repo.connectCloud('expired')).thenThrow(
        DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 401),
          type: DioExceptionType.badResponse,
        ),
      );
      when(() => repo.connectCloud('approved')).thenAnswer((_) async => true);

      final router = GoRouter(
        initialLocation: Destinations.plexSignIn,
        routes: [
          GoRoute(
            path: Destinations.plexSignIn,
            builder: (_, _) => const PlexSignInScreen(),
          ),
          GoRoute(
            path: Destinations.home,
            builder: (_, _) => const Scaffold(body: Text('Home')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PlexSignInScreen)),
      );
      await tester.tap(find.text(l10n.plexFreeTvCloudTitle));
      await tester.pumpAndSettle();
      discovery.complete([]);
      await tester.pump();
      expect(find.text(l10n.plexFreeTvCloudTitle), findsNothing);
      await tester.tap(find.text(l10n.tryAgain));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.plexFreeTvCloudTitle));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      verify(() => repo.connectCloud('expired')).called(1);
      verify(() => repo.connectCloud('approved')).called(1);
    },
  );

  testWidgets('a stale cloud 401 preserves the newer approval', (tester) async {
    final tv = _PlexTv();
    final repo = _Repository();
    GetIt.instance.registerSingleton<PlexTvService>(tv);
    GetIt.instance.registerSingleton<PlexRepository>(repo);
    addTearDown(() => GetIt.instance.reset());

    final pinApproval = Completer<String?>();
    final passwordConnection = Completer<bool>();
    when(tv.createPin).thenAnswer(
      (_) async => PlexPin(id: 1, code: 'TEST', expiresAt: DateTime.utc(2100)),
    );
    when(() => tv.checkPin(1)).thenAnswer((_) => pinApproval.future);
    when(() => tv.signIn('viewer', 'password'))
        .thenAnswer((_) async => 'first');
    when(() => repo.loadServers(any())).thenAnswer((_) async => []);
    when(() => repo.connectCloud('first'))
        .thenAnswer((_) => passwordConnection.future);
    when(() => repo.connectCloud('second')).thenAnswer((_) async => false);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: PlexSignInScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    verify(() => tv.checkPin(1)).called(1);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(PlexSignInScreen)),
    );
    await tester.tap(find.text(l10n.plexSignInWithPassword));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'viewer');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.widgetWithIcon(OutlinedButton, Icons.login));
    await tester.pumpAndSettle();
    final freeTv = find.text(l10n.plexFreeTvCloudTitle);
    await tester.tap(freeTv);
    await tester.pump();
    verify(() => repo.connectCloud('first')).called(1);

    pinApproval.complete('second');
    await tester.pump();
    verify(() => repo.loadServers('second')).called(1);
    final request = RequestOptions(path: 'https://plex.tv/api/v2/user');
    passwordConnection.completeError(
      DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 401),
        type: DioExceptionType.badResponse,
      ),
    );
    await tester.pumpAndSettle();
    expect(freeTv, findsOneWidget);
    expect(find.text(l10n.tryAgain), findsNothing);
    await tester.tap(freeTv);
    await tester.pumpAndSettle();
    verify(() => repo.connectCloud('second')).called(1);
    verify(tv.createPin).called(1);
  });

  testWidgets('failed Plex connections keep both choices and the approved token', (
    tester,
  ) async {
    final tv = _PlexTv();
    final repo = _Repository();
    GetIt.instance.registerSingleton<PlexTvService>(tv);
    GetIt.instance.registerSingleton<PlexRepository>(repo);
    addTearDown(() => GetIt.instance.reset());
    const server = PlexServer(
      id: 'pms',
      name: 'Home PMS',
      version: '1',
      accessToken: 'pms',
      connections: [],
    );
    when(tv.createPin).thenAnswer(
      (_) async => PlexPin(id: 1, code: 'TEST', expiresAt: DateTime.utc(2100)),
    );
    when(() => tv.checkPin(1)).thenAnswer((_) async => 'token');
    when(() => repo.loadServers('token')).thenAnswer((_) async => [server]);
    when(() => repo.connect(server, 'token')).thenAnswer((_) async => false);
    when(() => repo.connectCloud('token')).thenAnswer((_) async => false);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: PlexSignInScreen(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text(server.name));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(PlexSignInScreen)),
    );
    expect(find.text(l10n.unableToConnectTo(server.name)), findsOneWidget);
    expect(find.text(server.name), findsOneWidget);
    await tester.tap(find.text(l10n.plexFreeTvCloudTitle));
    await tester.pumpAndSettle();
    expect(find.text(l10n.loginFailed), findsWidgets);
    expect(find.text(server.name), findsOneWidget);
    await tester.tap(find.text(server.name));
    await tester.pumpAndSettle();
    verify(() => repo.connectCloud('token')).called(1);
    verify(() => repo.connect(server, 'token')).called(2);
    verify(tv.createPin).called(1);
  });
}
