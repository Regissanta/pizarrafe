import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liga_pizarra/finance.dart';
import 'package:liga_pizarra/league_backend.dart';
import 'package:liga_pizarra/main.dart';

void main() {
  test('Firestore quota errors are distinguished from permission denials', () {
    final message = firebaseAuthMessage(
      FirebaseException(plugin: 'cloud_firestore', code: 'resource-exhausted'),
    );

    expect(message, contains('Quota exceeded'));
    expect(message, contains('No es un rechazo de reglas'));
  });

  Future<void> startGameFromSheet(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Iniciar partido'));
    await tester.tap(find.text('Iniciar partido'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      final player = find.byType(FilterChip).at(index);
      await tester.ensureVisible(player);
      await tester.tap(player);
      await tester.pump();
    }
    for (var index = 5; index < 10; index++) {
      final player = find.byType(FilterChip).at(10 + index);
      await tester.ensureVisible(player);
      await tester.tap(player);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Comenzar partido'));
    await tester.tap(find.text('Comenzar partido'));
    await tester.pumpAndSettle();
  }

  test('finance month choices show this month and the next month', () {
    expect(financePeriodChoices(DateTime(2026, 11)), ['2026-11', '2026-12']);
    expect(financePeriodChoices(DateTime(2026, 12)), ['2026-12', '2027-01']);
  });

  test('player game stats keep steals, turnovers, and blocks distinct', () {
    final oldLine = PlayerLine.fromJson({'playerId': 'p1', 'points': 8});
    expect(oldLine.steals, 0);
    expect(oldLine.turnovers, 0);
    expect(oldLine.blocks, 0);

    final line = PlayerLine(playerId: 'p1', steals: 4, turnovers: 3, blocks: 2);
    final restored = PlayerLine.fromJson(line.toJson());
    expect(restored.steals, 4);
    expect(restored.turnovers, 3);
    expect(restored.blocks, 2);
  });

  test('active state ID is replaced with a unique history ID', () {
    final game = Game(
      id: 'active',
      home: 'Local',
      away: 'Visitante',
      homePlayers: const [],
      awayPlayers: const [],
      mode: 'points',
      target: 21,
      durationSeconds: 600,
      startedAt: DateTime(2026, 1, 1),
    );

    game.ensureHistoryId();

    expect(game.id, isNot('active'));
    expect(game.id, isNotEmpty);
  });

  test('removing a point updates the selected player and team score', () {
    final game = Game(
      id: 'game-1',
      home: 'Local',
      away: 'Visitante',
      homePlayers: const ['p1'],
      awayPlayers: const [],
      mode: 'points',
      target: 21,
      durationSeconds: 600,
      startedAt: DateTime(2026, 1, 1),
      homeScore: 3,
      lines: [PlayerLine(playerId: 'p1', points: 3, threes: 1)],
    );

    expect(game.removePoint('home', playerId: 'p1'), isTrue);
    expect(game.homeScore, 2);
    expect(game.lineFor('p1').points, 2);
    expect(game.lineFor('p1').threes, 1);
    expect(game.toJson()['lines'].single['points'], 2);
  });

  test('correcting a three-pointer to a two-pointer updates both stats', () {
    final game = Game(
      id: 'game-1',
      home: 'Local',
      away: 'Visitante',
      homePlayers: const ['p1'],
      awayPlayers: const [],
      mode: 'points',
      target: 21,
      durationSeconds: 600,
      startedAt: DateTime(2026, 1, 1),
      homeScore: 3,
      lines: [PlayerLine(playerId: 'p1', points: 3, threes: 1)],
    );

    expect(
      game.removePoint('home', playerId: 'p1', correctThreeToTwo: true),
      isTrue,
    );
    expect(game.homeScore, 2);
    expect(game.lineFor('p1').points, 2);
    expect(game.lineFor('p1').threes, 0);
    expect(game.toJson()['lines'].single['threes'], 0);
  });

  test(
    'substitution preserves stats and records only finishers for results',
    () {
      final game = Game(
        id: 'game-1',
        home: 'Local',
        away: 'Visitante',
        homePlayers: ['p1', 'p2'],
        awayPlayers: ['p3'],
        mode: 'time',
        target: 21,
        durationSeconds: 600,
        startedAt: DateTime(2026, 1, 1),
        homeScore: 18,
        awayScore: 14,
        lines: [PlayerLine(playerId: 'p1', points: 6)],
      );

      expect(game.substitute('home', 'p1', 'p4'), isTrue);
      game.recordResultPlayers();
      final restored = Game.fromJson(game.toJson());

      expect(restored.homeScore, 18);
      expect(restored.homePlayers, containsAll(['p1', 'p2', 'p4']));
      expect(restored.lines.single.points, 6);
      expect(restored.resultPlayerIds, contains('p4'));
      expect(restored.resultPlayerIds, isNot(contains('p1')));
    },
  );

  test('a point cannot be removed from a player outside the team roster', () {
    final game = Game(
      id: 'game-1',
      home: 'Local',
      away: 'Visitante',
      homePlayers: const ['p1'],
      awayPlayers: const ['p2'],
      mode: 'points',
      target: 21,
      durationSeconds: 600,
      startedAt: DateTime(2026, 1, 1),
      homeScore: 3,
      lines: [PlayerLine(playerId: 'p2', points: 3)],
    );

    expect(game.removePoint('home', playerId: 'p2'), isFalse);
    expect(game.homeScore, 3);
    expect(game.lineFor('p2').points, 3);
  });

  test('WhatsApp payment links encode the full message', () {
    const message = 'Cuota de Ana Pérez: RD\$ 300';

    final uri = whatsAppShareUri(message);

    expect(uri.host, 'wa.me');
    expect(uri.queryParameters['text'], message);
  });

  test('member WhatsApp message includes only their monthly payments', () {
    final date = DateTime(2026, 11, 15);
    final payments = [
      FinanceEntry(
        id: 'p1-payment',
        kind: 'dues',
        period: '2026-11',
        date: date,
        amount: 100,
        category: 'dues',
        description: '',
        paymentMethod: 'cash',
        memberId: 'p1',
        memberName: 'Ana Pérez',
      ),
      FinanceEntry(
        id: 'p2-payment',
        kind: 'dues',
        period: '2026-11',
        date: date,
        amount: 300,
        category: 'dues',
        description: '',
        memberId: 'p2',
        memberName: 'Ana Pérez',
      ),
    ];

    final message = buildMemberDuesWhatsAppMessage(
      leagueName: 'Liga La Fe',
      memberId: 'p1',
      memberName: 'Ana Pérez',
      period: '2026-11',
      monthlyDues: 300,
      received: 100,
      payments: payments,
    );

    expect(message, contains('• 15/11/2026: RD\$ 100'));
    expect(message, contains('Pendiente: RD\$ 200'));
    expect(message, isNot(contains('• 15/11/2026: RD\$ 300')));
  });

  testWidgets('opens the league scoreboard in Spanish', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(LigaApp(backend: FakeLeagueBackend()));
    await tester.pumpAndSettle();

    expect(find.text('PIZARRAFE'), findsOneWidget);
    expect(
      find.text('Tu liga. Cada jugada.\nEn una sola pizarra.'),
      findsOneWidget,
    );
    expect(find.text('Miembro'), findsOneWidget);
  });

  testWidgets('opens the player registration form and saves a player', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(LigaApp(backend: FakeLeagueBackend()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Miembro').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agregar'));
    await tester.pumpAndSettle();

    expect(find.text('Registrar jugador'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Juan Pérez');
    await tester.tap(find.text('Guardar jugador'));
    await tester.pumpAndSettle();

    expect(find.text('Juan Pérez'), findsOneWidget);
  });

  testWidgets('administrator can edit player name without losing statistics', (
    tester,
  ) async {
    final players = [
      {'id': 'player-1', 'name': 'Juan Pérez'},
    ];
    final game = {
      'id': 'game-rename',
      'home': 'Local',
      'away': 'Visitante',
      'homePlayers': ['player-1', 'p1', 'p2', 'p3', 'p4'],
      'awayPlayers': ['p5', 'p6', 'p7', 'p8', 'p9'],
      'mode': 'points',
      'target': 21,
      'durationSeconds': 600,
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'homeScore': 21,
      'awayScore': 18,
      'remainingSeconds': 0,
      'running': false,
      'finished': true,
      'lines': [
        {'playerId': 'player-1', 'points': 12},
      ],
    };
    SharedPreferences.setMockInitialValues({
      'players': jsonEncode(players),
      'games': jsonEncode([game]),
    });
    final backend = FakeLeagueBackend(players: players, games: [game]);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Miembro').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Editar nombre'));
    await tester.pumpAndSettle();

    expect(find.text('Editar jugador'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Juan Actualizado');
    await tester.tap(find.text('Guardar cambios'));
    await tester.pumpAndSettle();

    expect(find.text('Juan Actualizado'), findsOneWidget);
    expect(find.text('Juan Pérez'), findsNothing);
    expect(find.textContaining('12 pts'), findsOneWidget);
    expect(backend.savedPlayers.single['name'], 'Juan Actualizado');
    expect(backend.savedGames.single['lines'].single['points'], 12);
  });

  testWidgets('ranks every player by the selected statistic', (tester) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    final game = {
      'id': 'game-1',
      'home': 'Local',
      'away': 'Visitante',
      'homePlayers': ['p0', 'p1', 'p2', 'p3', 'p4'],
      'awayPlayers': ['p5', 'p6', 'p7', 'p8', 'p9'],
      'mode': 'points',
      'target': 21,
      'durationSeconds': 600,
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'homeScore': 21,
      'awayScore': 18,
      'remainingSeconds': 0,
      'running': false,
      'finished': true,
      'lines': [
        {'playerId': 'p0', 'assists': 10},
        {'playerId': 'p1', 'assists': 18},
        {'playerId': 'p2', 'assists': 7},
      ],
    };
    SharedPreferences.setMockInitialValues({
      'players': jsonEncode(players),
      'games': jsonEncode([game]),
    });
    await tester.pumpWidget(
      LigaApp(backend: FakeLeagueBackend(players: players, games: [game])),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Comparar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Por estadística'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Puntos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Asistencias').last);
    await tester.pumpAndSettle();

    expect(find.text('18'), findsOneWidget);
    expect(find.text('Jugador 1'), findsWidgets);
    expect(find.text('Jugador 0'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Jugador 1')).dy,
      lessThan(tester.getTopLeft(find.text('Jugador 0')).dy),
    );
    expect(find.text('Jugador 9'), findsOneWidget);

    await tester.tap(find.text('Compañeros'));
    await tester.pumpAndSettle();
    expect(find.text('MEJORES COMPAÑEROS'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('MÁS DERROTAS JUNTOS'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('MÁS DERROTAS JUNTOS'), findsOneWidget);
    expect(find.text('Jugador 1'), findsWidgets);
  });

  testWidgets('filters stats by date and ranks game performance', (
    tester,
  ) async {
    final players = [
      {'id': 'p0', 'name': 'Jugador 0'},
      {'id': 'p1', 'name': 'Jugador 1'},
    ];
    final game = Game(
      id: 'performance-game',
      home: 'Local',
      away: 'Visitante',
      homePlayers: const ['p0'],
      awayPlayers: const ['p1'],
      mode: 'time',
      target: 21,
      durationSeconds: 600,
      startedAt: DateTime.now(),
      homeScore: 10,
      awayScore: 5,
      finished: true,
      resultPlayerIds: const ['p0', 'p1'],
      lines: [
        PlayerLine(playerId: 'p0', points: 8, assists: 3),
        PlayerLine(playerId: 'p1', points: 2),
      ],
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    await tester.pumpWidget(
      LigaApp(
        backend: FakeLeagueBackend(players: players, games: [game.toJson()]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comparar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Por estadística'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Siempre').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Día').last);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('${DateTime.now().day.toString().padLeft(2, '0')}/'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Mejor jugador'));
    await tester.tap(find.text('Mejor jugador'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Partido').last);
    await tester.pumpAndSettle();
    expect(find.text('Jugador 0'), findsOneWidget);
    expect(find.text('11'), findsOneWidget);
  });

  testWidgets('can increase and correct a live player rebound', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    await tester.pumpWidget(
      LigaApp(backend: FakeLeagueBackend(players: players)),
    );
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    await tester.tap(find.byTooltip('Sumar REB').first);
    await tester.pumpAndSettle();
    expect(find.text('REB 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Restar REB').first);
    await tester.pumpAndSettle();
    expect(find.text('REB 0'), findsNWidgets(10));

    await tester.ensureVisible(find.byTooltip('Sumar FP').first);
    await tester.tap(find.byTooltip('Sumar FP').first);
    await tester.pumpAndSettle();
    expect(find.text('FP 1'), findsOneWidget);

    expect(find.byTooltip('Sumar 3PT'), findsNothing);
  });

  testWidgets('quick stats and the score adjustment ask for a player', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    await tester.pumpWidget(
      LigaApp(backend: FakeLeagueBackend(players: players)),
    );
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    await tester.tap(find.byTooltip('Anotar AST').first);
    await tester.pumpAndSettle();
    expect(find.text('¿A quién anotar AST?'), findsOneWidget);
    await tester.tap(find.text('Jugador 0').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('AST 1'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('AST 1'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Sumar punto').first);
    await tester.tap(find.byTooltip('Sumar punto').first);
    await tester.pumpAndSettle();
    expect(find.text('¿Quién anotó 1 punto?'), findsOneWidget);
    expect(find.text('Punto sin atribuir'), findsNothing);
    await tester.tap(find.text('Jugador 0').last);
    await tester.pumpAndSettle();
    expect(find.text('PTS 1'), findsOneWidget);
  });

  testWidgets('a substitute keeps the outgoing player stats separate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final players = List.generate(
      11,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    await tester.pumpWidget(
      LigaApp(backend: FakeLeagueBackend(players: players)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Iniciar partido'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      await tester.tap(find.byType(FilterChip).at(index));
      await tester.pump();
    }
    for (var index = 16; index < 21; index++) {
      await tester.tap(find.byType(FilterChip).at(index));
      await tester.pump();
    }
    await tester.tap(find.text('Comenzar partido'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Sustituir Jugador 0').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jugador 10').last);
    await tester.pumpAndSettle();

    expect(find.text('Jugador 0 · En banca'), findsOneWidget);
    expect(find.text('Jugador 10'), findsOneWidget);
    expect(find.text('0'), findsNWidgets(2));
  });

  testWidgets('warns on every personal foul from the configured limit', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    await tester.pumpWidget(
      LigaApp(backend: FakeLeagueBackend(players: players)),
    );
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    final foulButton = find.byTooltip('Anotar FP').first;
    await tester.ensureVisible(foulButton);
    for (var foul = 1; foul <= 8; foul++) {
      await tester.tap(foulButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jugador 0').last);
      if (foul < 8) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    expect(find.textContaining('falta colectiva 8'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(foulButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jugador 0').last);
    await tester.pumpAndSettle();
    expect(find.text('FP 9'), findsOneWidget);
    expect(find.textContaining('falta colectiva 9'), findsOneWidget);
  });

  testWidgets(
    'a three-point score updates points and triples from the scoreboard',
    (tester) async {
      final players = List.generate(
        10,
        (index) => {'id': 'p$index', 'name': 'Jugador $index'},
      );
      SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
      await tester.pumpWidget(
        LigaApp(backend: FakeLeagueBackend(players: players)),
      );
      await tester.pumpAndSettle();
      await startGameFromSheet(tester);

      await tester.ensureVisible(find.text('+3').first);
      await tester.tap(find.text('+3').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jugador 0').last);
      await tester.pumpAndSettle();

      expect(find.text('3'), findsOneWidget);
      expect(find.text('3PT 0'), findsNWidgets(9));
      await tester.scrollUntilVisible(
        find.text('3PT 1'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('PTS 3'), findsOneWidget);
      expect(find.text('3PT 1'), findsOneWidget);

      await tester.ensureVisible(find.byTooltip('Restar punto').first);
      await tester.tap(find.byTooltip('Restar punto').first);
      await tester.pumpAndSettle();
      expect(find.text('¿A quién quitarle 1 punto?'), findsOneWidget);
      await tester.tap(find.text('3PT → 2PT'));
      await tester.pumpAndSettle();

      expect(find.text('2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('PTS 2'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('PTS 2'), findsOneWidget);
      expect(find.text('3PT 0'), findsNWidgets(10));
    },
  );

  testWidgets('reaching the points target automatically saves and closes', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    final backend = FakeLeagueBackend(players: players);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    for (var score = 0; score < 7; score++) {
      await tester.ensureVisible(find.text('+3').first);
      await tester.tap(find.text('+3').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Punto sin atribuir'));
      await tester.tap(find.text('Punto sin atribuir'));
      await tester.pumpAndSettle();
    }

    expect(backend.savedGames, hasLength(1));
    expect(backend.savedGames.single['homeScore'], 21);
    expect(backend.savedGames.single['finished'], isTrue);
    expect(backend.savedActiveGame, isNull);
    expect(find.text('ESTADÍSTICAS EN VIVO'), findsNothing);
  });

  testWidgets('two consecutive games are both preserved in history', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    final backend = FakeLeagueBackend(players: players);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    for (var gameNumber = 0; gameNumber < 2; gameNumber++) {
      await startGameFromSheet(tester);
      for (var score = 0; score < 7; score++) {
        await tester.ensureVisible(find.text('+3').first);
        await tester.tap(find.text('+3').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Punto sin atribuir'));
        await tester.tap(find.text('Punto sin atribuir'));
        await tester.pumpAndSettle();
      }
    }

    expect(backend.savedGames, hasLength(2));
    expect(backend.savedGames.map((game) => game['id']).toSet(), hasLength(2));
    expect(backend.savedGames.every((game) => game['id'] != 'active'), isTrue);
  });

  testWidgets('legacy result with reserved active ID is migrated', (
    tester,
  ) async {
    final legacyGame = {
      'id': 'active',
      'home': 'Local',
      'away': 'Visitante',
      'homePlayers': <String>[],
      'awayPlayers': <String>[],
      'mode': 'points',
      'target': 21,
      'durationSeconds': 600,
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'homeScore': 21,
      'awayScore': 18,
      'remainingSeconds': 0,
      'running': false,
      'finished': true,
      'lines': <Map<String, dynamic>>[],
    };
    final backend = FakeLeagueBackend(games: [legacyGame]);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    expect(backend.savedGames, hasLength(1));
    expect(backend.savedGames.single['id'], isNot('active'));
    await tester.tap(find.text('Historial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ver desglose del partido'));
    await tester.pumpAndSettle();
    expect(find.text('Local'), findsWidgets);
  });

  testWidgets('target finish is not blocked by a pending cloud sync', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    final backend = FakeLeagueBackend(players: players);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);
    backend.syncGate = Completer<void>();

    for (var score = 0; score < 7; score++) {
      await tester.ensureVisible(find.text('+3').first);
      await tester.tap(find.text('+3').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Punto sin atribuir'));
      await tester.tap(find.text('Punto sin atribuir'));
      await tester.pumpAndSettle();
    }

    expect(backend.savedGames.single['homeScore'], 21);
    expect(backend.savedGames.single['finished'], isTrue);
    expect(find.text('ESTADÍSTICAS EN VIVO'), findsNothing);
    backend.syncGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('can exit and discard an unfinished game without saving it', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    final backend = FakeLeagueBackend(players: players);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    await tester.ensureVisible(find.text('Finalizar'));
    await tester.tap(find.text('Finalizar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salir sin guardar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar partida'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('activeGame_main'), isNull);
    expect(preferences.getString('games_main'), jsonEncode([]));
    expect(backend.savedGames, isEmpty);
    expect(find.text('EN JUEGO'), findsNothing);
  });

  testWidgets('finalizing a game syncs the result and clears the active game', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    final backend = FakeLeagueBackend(players: players);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    await tester.ensureVisible(find.text('Finalizar').first);
    await tester.tap(find.text('Finalizar').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalizar').last);
    await tester.pumpAndSettle();

    expect(backend.savedGames, hasLength(1));
    expect(backend.savedGames.single['finished'], isTrue);
    expect(backend.savedActiveGame, isNull);
  });

  testWidgets('opening the app clears any previously active game', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    final activeGame = {
      'id': 'stale-active',
      'home': 'Local',
      'away': 'Visitante',
      'homePlayers': ['p0', 'p1', 'p2', 'p3', 'p4'],
      'awayPlayers': ['p5', 'p6', 'p7', 'p8', 'p9'],
      'mode': 'points',
      'target': 21,
      'durationSeconds': 600,
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'homeScore': 8,
      'awayScore': 6,
      'remainingSeconds': 600,
      'running': false,
      'finished': false,
      'lines': [],
    };
    SharedPreferences.setMockInitialValues({
      'players': jsonEncode(players),
      'activeGame_main': jsonEncode(activeGame),
    });
    final backend = FakeLeagueBackend(players: players, activeGame: activeGame);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.text('Iniciar partido'), findsOneWidget);
    expect(find.text('ESTADÍSTICAS EN VIVO'), findsNothing);
    expect(backend.savedActiveGame, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('activeGame_main'), isNull);
  });

  testWidgets('a failed Firestore finish does not mark the game as saved', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    SharedPreferences.setMockInitialValues({'players': jsonEncode(players)});
    final backend = FakeLeagueBackend(players: players)..failFinish = true;
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await startGameFromSheet(tester);

    for (var score = 0; score < 7; score++) {
      await tester.ensureVisible(find.text('+3').first);
      await tester.tap(find.text('+3').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Punto sin atribuir'));
      await tester.tap(find.text('Punto sin atribuir'));
      await tester.pumpAndSettle();
    }

    expect(backend.savedGames, isEmpty);
    expect(backend.savedActiveGame, isNotNull);
    expect(find.text('ESTADÍSTICAS EN VIVO'), findsOneWidget);
    expect(find.text('Reintentar guardado'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '+1').first)
          .onPressed,
      isNull,
    );
  });

  testWidgets('new accounts get viewer-only access by default', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakeLeagueBackend(identity: null);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Crear cuenta'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'nuevoJugador');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.enterText(
      find.byType(TextField).at(2),
      'ABCDEFGHJKLMNPQRST23',
    );
    await tester.tap(find.text('Crear cuenta').last);
    await tester.pumpAndSettle();

    expect(backend.registeredInvitationCode, 'ABCDEFGHJKLMNPQRST23');
    await tester.tap(find.text('Cuenta'));
    await tester.pumpAndSettle();
    expect(find.text('nuevojugador'), findsOneWidget);
    expect(find.text('Lector · Solo consulta'), findsOneWidget);
    await tester.tap(find.text('Miembro'));
    await tester.pumpAndSettle();
    expect(find.text('Agregar'), findsNothing);
  });

  testWidgets('owner creates a league and an administrator invitation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(LigaApp(backend: FakeLeagueBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cuenta'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Crear liga e invitar administrador'));
    await tester.tap(find.text('Crear liga e invitar administrador'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Liga del Este');
    await tester.tap(find.text('Crear').last);
    await tester.pumpAndSettle();

    expect(find.text('Invitación creada'), findsOneWidget);
    expect(find.text('ABCDEFGHJKLMNPQRST23'), findsOneWidget);
    expect(
      find.textContaining('administrador de Liga del Este'),
      findsOneWidget,
    );
  });

  testWidgets('records partial monthly dues and maintenance expenses', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final players = [
      {'id': 'p1', 'name': 'Ana Pérez'},
    ];
    final backend = FakeLeagueBackend(players: players);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Finanzas'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Registrar cuota'));
    await tester.tap(find.text('Registrar cuota'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '100');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Abonado RD\$ 100'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Abonado RD\$ 100'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Registrar cuota'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Registrar cuota'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Registrar cuota'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '200');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Abonado RD\$ 300 de RD\$ 300'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Abonado RD\$ 300 de RD\$ 300'), findsOneWidget);
    expect(find.text('Completa'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Registrar gasto'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Registrar gasto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Registrar gasto'));
    await tester.pumpAndSettle();
    final expenseCategory = find.byType(DropdownButton<String>).last;
    await tester.ensureVisible(expenseCategory);
    await tester.tap(expenseCategory);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mantenimiento de cancha').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Cancha Central');
    await tester.enterText(find.byType(TextField).last, '500');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    expect(backend.savedFinanceEntries.last['category'], 'maintenance');
    expect(backend.savedFinanceEntries.last['description'], 'Cancha Central');
    await tester.dragFrom(const Offset(200, 400), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Mantenimiento de cancha'), findsWidgets);
    expect(find.textContaining('Cancha Central'), findsWidgets);
    expect(find.text('-RD\$ 500'), findsWidgets);
  });

  testWidgets('configures a generic contributor and records VISITAS', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakeLeagueBackend();
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finanzas'));
    await tester.pumpAndSettle();
    expect(find.text('Aporte de Carlos'), findsNothing);

    await tester.ensureVisible(find.byTooltip('Configuración de finanzas'));
    await tester.tap(find.byTooltip('Configuración de finanzas'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), 'María López');
    await tester.tap(find.text('Guardar').last);
    await tester.pumpAndSettle();
    expect(backend.contributionName, 'María López');
    expect(find.text('Aporte de María López'), findsOneWidget);

    await tester.ensureVisible(find.text('Aporte de María López'));
    await tester.tap(find.text('Aporte de María López'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '2000');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    expect(backend.savedFinanceEntries.last['kind'], 'pledge');
    expect(backend.savedFinanceEntries.last['memberName'], 'María López');

    await tester.dragFrom(const Offset(200, 250), const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Configuración de finanzas'));
    await tester.tap(find.byTooltip('Configuración de finanzas'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), '');
    await tester.tap(find.text('Guardar').last);
    await tester.pumpAndSettle();
    expect(backend.contributionName, isEmpty);
    expect(find.text('Aporte de María López'), findsNothing);

    await tester.ensureVisible(find.text('Registrar pago de VISITAS'));
    await tester.tap(find.text('Registrar pago de VISITAS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Equipo visitante');
    await tester.enterText(find.byType(TextField).last, '1');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    expect(backend.savedFinanceEntries.last['kind'], 'visits');
    expect(backend.savedFinanceEntries.last['category'], 'visits');
    expect(backend.savedFinanceEntries.last['memberName'], 'VISITAS');
    expect(backend.savedFinanceEntries.last['description'], 'Equipo visitante');
    expect(
      FinanceEntry.fromJson(backend.savedFinanceEntries.last).isIncome,
      isTrue,
    );
    await tester.ensureVisible(find.text('Registrar pago de VISITAS'));
    await tester.tap(find.text('Registrar pago de VISITAS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '2000000000');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    expect(backend.savedFinanceEntries.last['amount'], 2000000000);
    expect(backend.savedFinanceEntries.last['memberName'], 'VISITAS');
    await tester.scrollUntilVisible(
      find.text('+RD\$ 2,000,000,000'),
      200,
      scrollable: find.byType(Scrollable).hitTestable().first,
    );
    expect(find.text('VISITAS'), findsWidgets);
    expect(find.text('+RD\$ 2,000,000,000'), findsOneWidget);
  });

  testWidgets('administrator can configure the league monthly dues', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakeLeagueBackend(monthlyDues: 450);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finanzas'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining('RD\$ 450 POR JUGADOR'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('RD\$ 450 POR JUGADOR'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byTooltip('Configuración de finanzas'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('Configuración de finanzas'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '750');
    await tester.enterText(find.byType(TextFormField).last, '7');
    await tester.tap(find.text('Guardar').last);
    await tester.pumpAndSettle();
    expect(backend.teamFoulLimit, 7);

    await tester.tap(find.text('Registrar cuota'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cuota de RD\$ 750'), findsOneWidget);
  });

  testWidgets('records a future-month dues payment and its payment method', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final currentMonth = financePeriod(DateTime.now());
    final backend = FakeLeagueBackend(
      players: [
        {'id': 'p1', 'name': 'Ana Pérez'},
      ],
      financeEntries: [
        FinanceEntry(
          id: 'november-dues',
          kind: 'dues',
          period: currentMonth,
          date: DateTime.now(),
          amount: 300,
          category: 'dues',
          description: '',
          memberId: 'p1',
          memberName: 'Ana Pérez',
        ).toJson(),
      ],
    );
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finanzas'));
    await tester.pumpAndSettle();

    final nextMonth = financePeriod(
      DateTime(DateTime.now().year, DateTime.now().month + 1),
    );
    await tester.tap(find.text('Registrar cuota'));
    await tester.pumpAndSettle();
    final periodDropdown = find.byType(DropdownButtonFormField<String>).at(1);
    await tester.tap(periodDropdown);
    await tester.pumpAndSettle();
    final nextMonthOption = find.text(financePeriodLabel(nextMonth)).last;
    await tester.ensureVisible(nextMonthOption);
    await tester.pumpAndSettle();
    await tester.tap(nextMonthOption);
    await tester.pumpAndSettle();

    final paymentMethod = find.byType(DropdownButtonFormField<String>).last;
    await tester.tap(paymentMethod);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Depósito').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '300');
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();

    final payment = backend.savedFinanceEntries.last;
    expect(payment['period'], nextMonth);
    expect(payment['paymentMethod'], 'deposit');
    expect(backend.savedFinanceEntries, hasLength(2));
    expect(find.textContaining(financePeriodLabel(nextMonth)), findsWidgets);

    await tester.scrollUntilVisible(
      find.textContaining('Depósito'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Depósito'), findsOneWidget);
  });

  testWidgets('finance page offers WhatsApp sharing for members and groups', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      LigaApp(
        backend: FakeLeagueBackend(
          players: [
            {'id': 'p1', 'name': 'Ana Pérez'},
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finanzas'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Compartir pagos por WhatsApp'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Compartir pagos por WhatsApp'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byTooltip('Enviar estado por WhatsApp'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byTooltip('Enviar estado por WhatsApp'), findsOneWidget);
  });

  testWidgets('expands both complete rosters in compact saved results', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    final game = {
      'id': 'game-rosters',
      'home': 'Ganadores',
      'away': 'Contrarios',
      'homePlayers': ['p0', 'p1', 'p2', 'p3', 'p4'],
      'awayPlayers': ['p5', 'p6', 'p7', 'p8', 'p9'],
      'mode': 'points',
      'target': 21,
      'durationSeconds': 600,
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'homeScore': 21,
      'awayScore': 18,
      'remainingSeconds': 0,
      'running': false,
      'finished': true,
      'lines': [
        {'playerId': 'p0', 'points': 21},
      ],
    };
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      LigaApp(backend: FakeLeagueBackend(players: players, games: [game])),
    );
    await tester.pumpAndSettle();

    expect(find.text('Jugador 0'), findsNothing);

    await tester.tap(find.text('Historial'));
    await tester.pumpAndSettle();
    expect(find.text('Jugador 0'), findsNothing);
    await tester.tap(find.text('Ver desglose del partido'));
    await tester.pumpAndSettle();
    expect(find.text('Jugador 0'), findsOneWidget);
    expect(find.text('Jugador 9'), findsOneWidget);
    expect(find.text('Contrarios'), findsWidgets);
  });

  testWidgets('administrator can delete a saved game and its statistics', (
    tester,
  ) async {
    final players = List.generate(
      10,
      (index) => {'id': 'p$index', 'name': 'Jugador $index'},
    );
    final game = {
      'id': 'game-delete',
      'home': 'Local',
      'away': 'Visitante',
      'homePlayers': ['p0', 'p1', 'p2', 'p3', 'p4'],
      'awayPlayers': ['p5', 'p6', 'p7', 'p8', 'p9'],
      'mode': 'points',
      'target': 21,
      'durationSeconds': 600,
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'homeScore': 21,
      'awayScore': 18,
      'remainingSeconds': 0,
      'running': false,
      'finished': true,
      'lines': [
        {'playerId': 'p0', 'points': 21},
      ],
    };
    SharedPreferences.setMockInitialValues({
      'games': jsonEncode([game]),
    });
    final backend = FakeLeagueBackend(players: players, games: [game]);
    await tester.pumpWidget(LigaApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Historial'));
    await tester.pumpAndSettle();
    expect(find.text('Ver desglose del partido'), findsOneWidget);
    expect(find.text('p0'), findsNothing);
    await tester.tap(find.text('Ver desglose del partido'));
    await tester.pumpAndSettle();
    expect(find.text('Local'), findsWidgets);
    await tester.tap(find.text('Eliminar partido'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar partido').last);
    await tester.pumpAndSettle();

    expect(backend.savedGames, isEmpty);
    expect(find.text('Local'), findsNothing);
    expect(find.text('Sin resultados todavía'), findsOneWidget);
  });
}

class FakeLeagueBackend implements LeagueBackend {
  FakeLeagueBackend({
    LeagueIdentity? identity = const LeagueIdentity('owner'),
    String role = 'owner',
    List<Map<String, dynamic>> players = const [],
    List<Map<String, dynamic>> games = const [],
    List<Map<String, dynamic>> financeEntries = const [],
    Map<String, dynamic>? activeGame,
    this.monthlyDues = 300,
  }) : _identity = identity,
       _players = List.of(players),
       _games = List.of(games),
       _financeEntries = List.of(financeEntries),
       _activeGame = activeGame {
    if (identity != null) {
      _users.add({'uid': identity.uid, 'username': 'owner', 'role': role});
    }
  }

  LeagueIdentity? _identity;
  final List<Map<String, dynamic>> _players;
  final List<Map<String, dynamic>> _games;
  final List<Map<String, dynamic>> _financeEntries;
  Map<String, dynamic>? _activeGame;
  int monthlyDues;
  int teamFoulLimit = 8;
  String contributionName = '';
  bool failFinish = false;
  Completer<void>? syncGate;
  final List<Map<String, dynamic>> _users = [];
  final _authEvents = StreamController<LeagueIdentity?>.broadcast();
  final _financeEvents =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final Map<String, Map<String, dynamic>> _profiles = {};
  String? registeredInvitationCode;

  List<Map<String, dynamic>> get savedGames => _games;
  List<Map<String, dynamic>> get savedPlayers => _players;
  List<Map<String, dynamic>> get savedFinanceEntries => _financeEntries;
  Map<String, dynamic>? get savedActiveGame => _activeGame;

  @override
  LeagueIdentity? get currentUser => _identity;

  @override
  Stream<LeagueIdentity?> get authChanges => Stream.multi((controller) {
    controller.add(_identity);
    final subscription = _authEvents.stream.listen(controller.add);
    controller.onCancel = subscription.cancel;
  });

  @override
  Future<void> signIn(String username, String password) async {
    _identity = const LeagueIdentity('signed-in');
    _profiles[_identity!.uid] = {
      'uid': _identity!.uid,
      'username': username.toLowerCase(),
      'role': 'viewer',
    };
    _authEvents.add(_identity);
  }

  @override
  Future<void> register(
    String username,
    String password,
    String invitationCode,
  ) async {
    if (invitationCode.trim().isEmpty) {
      throw const FormatException('Se requiere una invitación.');
    }
    registeredInvitationCode = invitationCode;
    _identity = const LeagueIdentity('new-user');
    _profiles[_identity!.uid] = {
      'uid': _identity!.uid,
      'username': username.toLowerCase(),
      'role': 'viewer',
    };
    _users.add(_profiles[_identity!.uid]!);
    _authEvents.add(_identity);
  }

  @override
  Future<void> signOut() async {
    _identity = null;
    _authEvents.add(null);
  }

  @override
  Stream<Map<String, dynamic>?> watchProfile(String uid) => Stream.value(
    _profiles[uid] ??
        _users.firstWhere(
          (user) => user['uid'] == uid,
          orElse: () => {'uid': uid, 'username': 'owner', 'role': 'owner'},
        ),
  );

  @override
  Stream<Map<String, dynamic>?> watchLeague(String leagueId) => Stream.value({
    'name': 'Liga La Fe',
    'monthlyDues': monthlyDues,
    'teamFoulLimit': teamFoulLimit,
  });

  @override
  Stream<List<Map<String, dynamic>>> watchAvailableLeagues(
    String uid,
    bool isOwner,
  ) => Stream.value([
    {
      'id': 'main',
      'name': 'Liga La Fe',
      'role': isOwner ? 'owner' : 'viewer',
      'monthlyDues': monthlyDues,
      'teamFoulLimit': teamFoulLimit,
    },
  ]);

  @override
  Stream<List<Map<String, dynamic>>> watchLeagueMembers(String leagueId) =>
      Stream.value(_users);

  @override
  Future<void> ensureLegacyLeague(String uid) async {}

  @override
  Future<void> migrateLegacyUsers() async {}

  @override
  Future<String> createLeague(String name) async => 'new-league';

  @override
  Future<void> updateMonthlyDues(String leagueId, int amount) async {
    monthlyDues = amount;
  }

  @override
  Future<void> updateFinanceSettings(
    String leagueId,
    int amount,
    String name,
    int? foulLimit,
  ) async {
    monthlyDues = amount;
    contributionName = name;
    if (foulLimit != null) teamFoulLimit = foulLimit;
  }

  @override
  Future<String> createInvitation(String leagueId, String role) async =>
      'ABCDEFGHJKLMNPQRST23';

  @override
  Future<void> redeemInvitation(String code) async {}

  @override
  Stream<List<Map<String, dynamic>>> watchPlayers(String leagueId) =>
      Stream.value(_players);

  @override
  Stream<List<Map<String, dynamic>>> watchGames(String leagueId) =>
      Stream.value(_games);

  @override
  Stream<Map<String, dynamic>?> watchActiveGame(String leagueId) =>
      Stream.value(_activeGame);

  @override
  Stream<List<Map<String, dynamic>>> watchFinanceEntries(String leagueId) =>
      Stream.multi((controller) {
        controller.add(_financeEntries);
        final subscription = _financeEvents.stream.listen(controller.add);
        controller.onCancel = subscription.cancel;
      });

  @override
  Future<void> changeRole(String leagueId, String uid, String role) async {
    for (final user in _users) {
      if (user['uid'] == uid) user['role'] = role;
    }
  }

  @override
  Future<void> deletePlayer(String leagueId, String id) async {}

  @override
  Future<void> deleteGame(String leagueId, String id) async {
    _games.removeWhere((game) => game['id'] == id);
  }

  @override
  Future<void> migrateLegacyActiveResult(String leagueId) async {
    final legacyIndex = _games.indexWhere((game) => game['id'] == 'active');
    if (legacyIndex == -1) return;
    _games[legacyIndex] = {..._games[legacyIndex], 'id': 'migrated-active'};
  }

  @override
  Future<void> finishGame(
    String leagueId,
    Map<String, dynamic> game,
    String activeGameId,
  ) async {
    if (failFinish) throw StateError('permission-denied');
    _games.removeWhere((savedGame) => savedGame['id'] == game['id']);
    _games.add(Map<String, dynamic>.from(game));
    _activeGame = null;
  }

  @override
  Future<void> clearActiveGame(String leagueId, String activeGameId) async {
    _activeGame = null;
  }

  @override
  Future<void> addFinanceEntry(
    String leagueId,
    Map<String, dynamic> entry,
  ) async {
    _financeEntries.add(Map.of(entry));
    _financeEvents.add(_financeEntries);
  }

  @override
  Future<void> syncLeague({
    required String leagueId,
    required List<Map<String, dynamic>> players,
    required List<Map<String, dynamic>> games,
    required Map<String, dynamic>? activeGame,
  }) async {
    final gate = syncGate;
    if (gate != null) await gate.future;
    final hasFinishedGames = _games.any((game) => game['finished'] == true);
    if (hasFinishedGames &&
        games.every(
          (game) => !_games.any((savedGame) => savedGame['id'] == game['id']),
        )) {
      throw StateError('Stale game snapshot rejected.');
    }
    _players
      ..clear()
      ..addAll(players.map(Map<String, dynamic>.from));
    _games
      ..clear()
      ..addAll(games.map(Map<String, dynamic>.from));
    _activeGame =
        activeGame == null ? null : Map<String, dynamic>.from(activeGame);
  }
}
