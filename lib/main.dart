import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'finance.dart';
import 'firebase_web_options.dart';
import 'league_backend.dart';

const _background = Color(0xFF0B1020);
const _surface = Color(0xFF151D31);
const _muted = Color(0xFF8C9AB5);
const _orange = Color(0xFFFF8A3D);
const _blue = Color(0xFF54B6FF);
const _defaultMonthlyDues = 300;
const _contributionPledge = 2000;
const _legacyCarlosContributionId = 'carlos-figuereo';
const _leagueContributionId = 'league-contribution';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  try {
    await Firebase.initializeApp(
      options: kIsWeb ? FirebaseWebOptions.current : null,
    );
    runApp(const LigaApp());
  } catch (error) {
    runApp(_FirebaseSetupApp(error: error));
  }
}

class Player {
  Player({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Player.fromJson(Map<String, dynamic> json) =>
      Player(id: json['id'] as String, name: json['name'] as String);
}

class PlayerLine {
  PlayerLine({
    required this.playerId,
    this.points = 0,
    this.rebounds = 0,
    this.assists = 0,
    this.threes = 0,
    this.steals = 0,
    this.turnovers = 0,
    this.blocks = 0,
    this.personalFouls = 0,
  });

  final String playerId;
  int points;
  int rebounds;
  int assists;
  int threes;
  int steals;
  int turnovers;
  int blocks;
  int personalFouls;

  Map<String, dynamic> toJson() => {
    'playerId': playerId,
    'points': points,
    'rebounds': rebounds,
    'assists': assists,
    'threes': threes,
    'steals': steals,
    'turnovers': turnovers,
    'blocks': blocks,
    'personalFouls': personalFouls,
  };

  factory PlayerLine.fromJson(Map<String, dynamic> json) => PlayerLine(
    playerId: json['playerId'] as String,
    points: json['points'] as int? ?? 0,
    rebounds: json['rebounds'] as int? ?? 0,
    assists: json['assists'] as int? ?? 0,
    threes: json['threes'] as int? ?? 0,
    steals: json['steals'] as int? ?? 0,
    turnovers: json['turnovers'] as int? ?? 0,
    blocks: json['blocks'] as int? ?? 0,
    personalFouls: json['personalFouls'] as int? ?? 0,
  );
}

class Game {
  Game({
    required this.id,
    required this.home,
    required this.away,
    required this.homePlayers,
    required this.awayPlayers,
    required this.mode,
    required this.target,
    required this.durationSeconds,
    required this.startedAt,
    List<String>? activeHomePlayers,
    List<String>? activeAwayPlayers,
    this.resultPlayerIds,
    this.homeScore = 0,
    this.awayScore = 0,
    this.remainingSeconds = 0,
    this.running = false,
    this.finished = false,
    this.lines = const [],
  }) : activeHomePlayers = activeHomePlayers ?? List.of(homePlayers),
       activeAwayPlayers = activeAwayPlayers ?? List.of(awayPlayers);

  String id;
  final String home;
  final String away;
  final List<String> homePlayers;
  final List<String> awayPlayers;
  List<String> activeHomePlayers;
  List<String> activeAwayPlayers;
  List<String>? resultPlayerIds;
  final String mode;
  final int target;
  final int durationSeconds;
  final DateTime startedAt;
  int homeScore;
  int awayScore;
  int remainingSeconds;
  bool running;
  bool finished;
  List<PlayerLine> lines;

  PlayerLine lineFor(String playerId) {
    return lines.firstWhere(
      (line) => line.playerId == playerId,
      orElse: () {
        final line = PlayerLine(playerId: playerId);
        lines = [...lines, line];
        return line;
      },
    );
  }

  List<String> activePlayersFor(String team) =>
      team == 'home' ? activeHomePlayers : activeAwayPlayers;

  bool substitute(String team, String outgoingId, String incomingId) {
    if (team != 'home' && team != 'away' || outgoingId == incomingId) {
      return false;
    }
    final active = activePlayersFor(team);
    final teamPlayers = team == 'home' ? homePlayers : awayPlayers;
    final opponents = team == 'home' ? awayPlayers : homePlayers;
    if (!active.contains(outgoingId) ||
        active.contains(incomingId) ||
        opponents.contains(incomingId)) {
      return false;
    }
    if (!teamPlayers.contains(incomingId)) teamPlayers.add(incomingId);
    active[active.indexOf(outgoingId)] = incomingId;
    return true;
  }

  void recordResultPlayers() {
    resultPlayerIds = [...activeHomePlayers, ...activeAwayPlayers];
  }

  bool removePoint(
    String team, {
    required String playerId,
    bool correctThreeToTwo = false,
  }) {
    if (team != 'home' && team != 'away') return false;
    final score = team == 'home' ? homeScore : awayScore;
    if (score <= 0) return false;

    final roster = team == 'home' ? homePlayers : awayPlayers;
    if (!roster.contains(playerId)) return false;
    final playerLines = lines.where((line) => line.playerId == playerId);
    if (playerLines.isEmpty || playerLines.first.points <= 0) return false;
    final line = playerLines.first;
    if (correctThreeToTwo && (line.points < 3 || line.threes == 0)) {
      return false;
    }

    if (team == 'home') {
      homeScore--;
    } else {
      awayScore--;
    }
    line.points--;
    if (correctThreeToTwo) line.threes--;
    return true;
  }

  void ensureHistoryId() {
    if (id == 'active') {
      id = DateTime.now().microsecondsSinceEpoch.toString();
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'home': home,
    'away': away,
    'homePlayers': homePlayers,
    'awayPlayers': awayPlayers,
    'activeHomePlayers': activeHomePlayers,
    'activeAwayPlayers': activeAwayPlayers,
    'resultPlayerIds': resultPlayerIds,
    'mode': mode,
    'target': target,
    'durationSeconds': durationSeconds,
    'startedAt': startedAt.toIso8601String(),
    'homeScore': homeScore,
    'awayScore': awayScore,
    'remainingSeconds': remainingSeconds,
    'running': running,
    'finished': finished,
    'lines': lines.map((line) => line.toJson()).toList(),
  };

  factory Game.fromJson(Map<String, dynamic> json) => Game(
    id: json['id'] as String,
    home: json['home'] as String,
    away: json['away'] as String,
    homePlayers: List<String>.from(json['homePlayers'] as List? ?? []),
    awayPlayers: List<String>.from(json['awayPlayers'] as List? ?? []),
    activeHomePlayers: List<String>.from(
      json['activeHomePlayers'] as List? ?? json['homePlayers'] as List? ?? [],
    ),
    activeAwayPlayers: List<String>.from(
      json['activeAwayPlayers'] as List? ?? json['awayPlayers'] as List? ?? [],
    ),
    resultPlayerIds: (json['resultPlayerIds'] as List?)?.cast<String>(),
    mode: json['mode'] as String? ?? 'points',
    target: json['target'] as int? ?? 21,
    durationSeconds: json['durationSeconds'] as int? ?? 600,
    startedAt: DateTime.parse(json['startedAt'] as String),
    homeScore: json['homeScore'] as int? ?? 0,
    awayScore: json['awayScore'] as int? ?? 0,
    remainingSeconds: json['remainingSeconds'] as int? ?? 0,
    running: json['running'] as bool? ?? false,
    finished: json['finished'] as bool? ?? false,
    lines:
        (json['lines'] as List? ?? [])
            .map((item) => PlayerLine.fromJson(item as Map<String, dynamic>))
            .toList(),
  );
}

class PlayerTotals {
  int games = 0;
  int wins = 0;
  int losses = 0;
  int points = 0;
  int rebounds = 0;
  int assists = 0;
  int threes = 0;
  int steals = 0;
  int turnovers = 0;
  int blocks = 0;
  int personalFouls = 0;
}

class _TeammateRecord {
  int games = 0;
  int wins = 0;
  int losses = 0;
  int draws = 0;
}

class LigaApp extends StatefulWidget {
  const LigaApp({super.key, this.backend});

  final LeagueBackend? backend;

  @override
  State<LigaApp> createState() => _LigaAppState();
}

class _LigaAppState extends State<LigaApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final LeagueBackend _backend;
  StreamSubscription<LeagueIdentity?>? _authSubscription;
  StreamSubscription<Map<String, dynamic>?>? _profileSubscription;
  StreamSubscription<Map<String, dynamic>?>? _leagueMetadataSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _leagueOptionsSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _playersSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _gamesSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _financeSubscription;
  StreamSubscription<Map<String, dynamic>?>? _activeGameSubscription;
  LeagueIdentity? _identity;
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _availableLeagues = [];
  String? _selectedLeagueId;
  String? _selectedLeagueRole;
  List<Map<String, dynamic>> _localPlayers = [];
  List<Map<String, dynamic>> _localGames = [];
  List<Player> players = [];
  List<Game> games = [];
  List<FinanceEntry> financeEntries = [];
  Game? activeGame;
  Timer? _timer;
  bool _localLoaded = false;
  bool _authResolved = false;
  bool _profileLoaded = false;
  bool _leagueOptionsLoaded = false;
  bool _leagueOptionsStarted = false;
  bool _playersLoaded = false;
  bool _gamesLoaded = false;
  bool _financeLoaded = false;
  bool _activeGameLoaded = false;
  bool _migrationStarted = false;
  bool _startupStateHandled = false;
  bool _finishingGame = false;
  String? _finishError;
  String? _cloudError;
  Future<void> _saveQueue = Future<void>.value();
  Future<void> _cloudSaveQueue = Future<void>.value();
  int _tab = 0;
  String _selectedFinancePeriod = financePeriod(DateTime.now());

  bool get _canWrite => _isOwner || _selectedLeagueRole == 'admin';
  bool get _isOwner => _profile?['role'] == 'owner';
  int get _monthlyDues {
    for (final league in _availableLeagues) {
      if (league['id'] == _selectedLeagueId) {
        final amount = league['monthlyDues'];
        if (amount is int && amount > 0) return amount;
      }
    }
    return _defaultMonthlyDues;
  }

  String get _contributionName {
    for (final league in _availableLeagues) {
      if (league['id'] == _selectedLeagueId) {
        return (league['contributionName'] as String? ?? '').trim();
      }
    }
    return '';
  }

  int get _teamFoulLimit {
    for (final league in _availableLeagues) {
      if (league['id'] == _selectedLeagueId) {
        final limit = league['teamFoulLimit'];
        if (limit is int && limit > 0) return limit;
      }
    }
    return 8;
  }

  String get _selectedLeagueName {
    for (final league in _availableLeagues) {
      if (league['id'] == _selectedLeagueId) {
        return league['name'] as String? ?? 'Liga';
      }
    }
    return 'Liga';
  }

  bool get _cloudLoaded =>
      _profileLoaded &&
      _leagueOptionsLoaded &&
      (_selectedLeagueId == null ||
          (_playersLoaded &&
              _gamesLoaded &&
              _activeGameLoaded &&
              _financeLoaded));

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? FirebaseLeagueBackend();
    _loadLocal();
    _authSubscription = _backend.authChanges.listen(
      _onAuthChanged,
      onError: (Object error) => _reportCloudError(error, fatal: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _authSubscription?.cancel();
    _profileSubscription?.cancel();
    _leagueMetadataSubscription?.cancel();
    _leagueOptionsSubscription?.cancel();
    _playersSubscription?.cancel();
    _gamesSubscription?.cancel();
    _financeSubscription?.cancel();
    _activeGameSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final playerData = prefs.getString('players');
    final gameData = prefs.getString('games');
    if (!mounted) return;
    setState(() {
      if (playerData != null) {
        _localPlayers =
            (jsonDecode(playerData) as List)
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList();
      }
      if (gameData != null) {
        _localGames =
            (jsonDecode(gameData) as List)
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList();
      }
      _localLoaded = true;
    });
    _finishCloudLoadIfReady();
  }

  void _onAuthChanged(LeagueIdentity? identity) {
    _timer?.cancel();
    _profileSubscription?.cancel();
    _leagueMetadataSubscription?.cancel();
    _leagueOptionsSubscription?.cancel();
    _playersSubscription?.cancel();
    _gamesSubscription?.cancel();
    _financeSubscription?.cancel();
    _activeGameSubscription?.cancel();

    setState(() {
      _identity = identity;
      _profile = null;
      _availableLeagues = [];
      _selectedLeagueId = null;
      _selectedLeagueRole = null;
      _authResolved = true;
      _profileLoaded = identity == null;
      _leagueOptionsLoaded = identity == null;
      _leagueOptionsStarted = false;
      _playersLoaded = true;
      _gamesLoaded = true;
      _financeLoaded = true;
      _activeGameLoaded = true;
      _migrationStarted = false;
      _startupStateHandled = false;
      _cloudError = null;
      _tab = 0;
      if (identity == null) {
        players = [];
        games = [];
        financeEntries = [];
        activeGame = null;
      } else {
        players = [];
        games = [];
        financeEntries = [];
        activeGame = null;
      }
    });

    if (identity == null) return;
    _profileSubscription = _backend.watchProfile(identity.uid).listen((
      profile,
    ) {
      if (!mounted || _identity?.uid != identity.uid) return;
      setState(() {
        _profile = profile;
        _profileLoaded = profile != null;
        _cloudError =
            profile == null ? 'No se encontró el perfil de usuario.' : null;
      });
      if (profile != null && !_leagueOptionsStarted) {
        _leagueOptionsStarted = true;
        _loadAvailableLeagues(identity, profile);
      }
      _finishCloudLoadIfReady();
    }, onError: (Object error) => _reportCloudError(error, fatal: true));
  }

  Future<void> _loadAvailableLeagues(
    LeagueIdentity identity,
    Map<String, dynamic> profile,
  ) async {
    try {
      final owner = profile['role'] == 'owner';
      if (owner) await _backend.ensureLegacyLeague(identity.uid);
      if (!mounted || _identity?.uid != identity.uid) return;
      _leagueOptionsSubscription = _backend
          .watchAvailableLeagues(identity.uid, owner)
          .listen((leagues) {
            if (!mounted || _identity?.uid != identity.uid) return;
            final currentExists = leagues.any(
              (league) => league['id'] == _selectedLeagueId,
            );
            final nextId =
                currentExists
                    ? _selectedLeagueId
                    : leagues.any((league) => league['id'] == 'main')
                    ? 'main'
                    : leagues.isEmpty
                    ? null
                    : leagues.first['id'] as String;
            setState(() {
              _availableLeagues = leagues;
              _leagueOptionsLoaded = true;
            });
            if (nextId != _selectedLeagueId) _selectLeague(nextId);
            _finishCloudLoadIfReady();
          }, onError: (Object error) => _reportCloudError(error, fatal: true));
    } catch (error) {
      _reportCloudError(error, fatal: true);
    }
  }

  void _selectLeague(String? leagueId) {
    _timer?.cancel();
    _playersSubscription?.cancel();
    _gamesSubscription?.cancel();
    _activeGameSubscription?.cancel();
    _leagueMetadataSubscription?.cancel();
    _financeSubscription?.cancel();
    final selected = _availableLeagues.where(
      (league) => league['id'] == leagueId,
    );
    setState(() {
      _selectedLeagueId = leagueId;
      _selectedLeagueRole =
          selected.isEmpty ? null : selected.first['role'] as String?;
      players = [];
      games = [];
      financeEntries = [];
      activeGame = null;
      _playersLoaded = leagueId == null;
      _gamesLoaded = leagueId == null;
      _activeGameLoaded = leagueId == null;
      _financeLoaded = leagueId == null;
      _migrationStarted = false;
      _startupStateHandled = false;
      _localLoaded = false;
    });
    if (leagueId == null) {
      _loadLocalForLeague(null);
      _finishCloudLoadIfReady();
      return;
    }
    _loadLocalForLeague(leagueId);
    if (_canWrite) {
      _backend
          .migrateLegacyActiveResult(leagueId)
          .catchError((Object error) => _reportCloudError(error));
    }
    _leagueMetadataSubscription = _backend.watchLeague(leagueId).listen((
      metadata,
    ) {
      if (!mounted || _selectedLeagueId != leagueId || metadata == null) {
        return;
      }
      setState(() {
        _availableLeagues = [
          for (final league in _availableLeagues)
            if (league['id'] == leagueId)
              {...league, ...metadata, 'id': leagueId}
            else
              league,
        ];
      });
    }, onError: (Object error) => _reportCloudError(error));
    _playersSubscription = _backend.watchPlayers(leagueId).listen((data) {
      if (!mounted || _selectedLeagueId != leagueId) return;
      setState(() {
        players = data.map(Player.fromJson).toList();
        _playersLoaded = true;
      });
      _finishCloudLoadIfReady();
    }, onError: (Object error) => _reportCloudError(error, fatal: true));
    _gamesSubscription = _backend.watchGames(leagueId).listen((data) {
      if (!mounted || _selectedLeagueId != leagueId) return;
      setState(() {
        games =
            data.map(Game.fromJson).toList()
              ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
        _gamesLoaded = true;
      });
      _finishCloudLoadIfReady();
    }, onError: (Object error) => _reportCloudError(error, fatal: true));
    _activeGameSubscription = _backend.watchActiveGame(leagueId).listen((data) {
      if (!mounted || _selectedLeagueId != leagueId) return;
      setState(() {
        activeGame = data == null ? null : Game.fromJson(data);
        _activeGameLoaded = true;
      });
      _finishCloudLoadIfReady();
    }, onError: (Object error) => _reportCloudError(error, fatal: true));
    _financeSubscription = _backend.watchFinanceEntries(leagueId).listen((
      data,
    ) {
      if (!mounted || _selectedLeagueId != leagueId) return;
      setState(() {
        financeEntries =
            data.map(FinanceEntry.fromJson).toList()
              ..sort((a, b) => b.date.compareTo(a.date));
        _financeLoaded = true;
      });
      _finishCloudLoadIfReady();
    }, onError: (Object error) => _reportCloudError(error, fatal: true));
  }

  Future<void> _loadLocalForLeague(String? leagueId) async {
    final prefs = await SharedPreferences.getInstance();
    final suffix = leagueId == null ? null : '_$leagueId';
    final playerData =
        suffix == null ? null : prefs.getString('players$suffix');
    final gameData = suffix == null ? null : prefs.getString('games$suffix');
    final useLegacy = leagueId == 'main';
    final savedPlayers =
        playerData ?? (useLegacy ? prefs.getString('players') : null);
    final savedGames =
        gameData ?? (useLegacy ? prefs.getString('games') : null);
    if (useLegacy) {
      if (playerData == null && savedPlayers != null) {
        await prefs.setString('players_main', savedPlayers);
      }
      if (gameData == null && savedGames != null) {
        await prefs.setString('games_main', savedGames);
      }
      await prefs.remove('players');
      await prefs.remove('games');
      await prefs.remove('activeGame');
    }
    if (!mounted || (leagueId != null && _selectedLeagueId != leagueId)) return;
    setState(() {
      _localPlayers =
          savedPlayers == null
              ? []
              : (jsonDecode(savedPlayers) as List)
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList();
      _localGames =
          savedGames == null
              ? []
              : (jsonDecode(savedGames) as List)
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList();
      _localLoaded = true;
    });
    _finishCloudLoadIfReady();
  }

  void _finishCloudLoadIfReady() {
    if (!_cloudLoaded || !mounted) return;
    if (!_migrationStarted &&
        _localLoaded &&
        _selectedLeagueId == 'main' &&
        _canWrite &&
        players.isEmpty &&
        games.isEmpty &&
        activeGame == null &&
        (_localPlayers.isNotEmpty || _localGames.isNotEmpty)) {
      _migrationStarted = true;
      players = _localPlayers.map(Player.fromJson).toList();
      games = _localGames.map(Game.fromJson).toList();
      _save().catchError((Object error) => _reportCloudError(error));
    }
    if (!_startupStateHandled && _localLoaded) {
      _startupStateHandled = true;
      final leagueId = _selectedLeagueId;
      final startupGameId = activeGame?.id;
      activeGame = null;
      _clearStartupGame(leagueId, startupGameId);
    }
    if (!_localLoaded) return;
    setState(() {});
  }

  Future<void> _clearStartupGame(
    String? leagueId,
    String? startupGameId,
  ) async {
    if (leagueId == null) return;
    try {
      await _enqueuePersistence(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('activeGame_$leagueId');
      });
      if (startupGameId != null && _canWrite) {
        await _backend.clearActiveGame(leagueId, startupGameId);
      }
    } catch (error) {
      _reportCloudError(error, fatal: startupGameId != null && _canWrite);
    }
  }

  void _reportCloudError(Object error, {bool fatal = false}) {
    if (!mounted) return;
    if (fatal) {
      setState(() => _cloudError = firebaseAuthMessage(error));
    }
    _messengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(firebaseAuthMessage(error))),
    );
  }

  Future<void> _enqueuePersistence(Future<void> Function() task) {
    final operation = _saveQueue.then((_) => task());
    _saveQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<void> _enqueueCloudSave(
    String leagueId,
    List<Map<String, dynamic>> playerData,
    List<Map<String, dynamic>> gameData,
    Map<String, dynamic>? activeGameData,
  ) {
    final operation = _cloudSaveQueue.then(
      (_) => _backend.syncLeague(
        leagueId: leagueId,
        players: playerData,
        games: gameData,
        activeGame: activeGameData,
      ),
    );
    _cloudSaveQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<void> _save({bool syncCloud = true}) async {
    final leagueId = _selectedLeagueId;
    final canSyncCloud = _canWrite && _cloudLoaded && syncCloud;
    final suffix = leagueId == null ? '' : '_$leagueId';
    final playerData = players.map((player) => player.toJson()).toList();
    final gameData = games.map((game) => game.toJson()).toList();
    final activeGameData = activeGame?.toJson();

    try {
      await _enqueuePersistence(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('players$suffix', jsonEncode(playerData));
        await prefs.setString('games$suffix', jsonEncode(gameData));
        if (activeGameData == null) {
          await prefs.remove('activeGame$suffix');
        } else {
          await prefs.setString(
            'activeGame$suffix',
            jsonEncode(activeGameData),
          );
        }
      });
      if (leagueId != null && canSyncCloud) {
        await _enqueueCloudSave(leagueId, playerData, gameData, activeGameData);
        if (mounted) setState(() => _cloudError = null);
      }
    } catch (error) {
      _reportCloudError(error, fatal: canSyncCloud);
    }
  }

  PlayerTotals totalsFor(String playerId) {
    final totals = PlayerTotals();
    for (final game in games.where((item) => item.finished)) {
      final appeared =
          game.homePlayers.contains(playerId) ||
          game.awayPlayers.contains(playerId);
      if (!appeared) continue;
      totals.games++;
      final eligibleForResult =
          game.resultPlayerIds == null ||
          game.resultPlayerIds!.contains(playerId);
      if (eligibleForResult && game.homeScore != game.awayScore) {
        final playerWon =
            game.homeScore > game.awayScore
                ? game.homePlayers.contains(playerId)
                : game.awayPlayers.contains(playerId);
        if (playerWon) {
          totals.wins++;
        } else {
          totals.losses++;
        }
      }
      for (final line in game.lines.where(
        (line) => line.playerId == playerId,
      )) {
        totals.points += line.points;
        totals.rebounds += line.rebounds;
        totals.assists += line.assists;
        totals.threes += line.threes;
        totals.steals += line.steals;
        totals.turnovers += line.turnovers;
        totals.blocks += line.blocks;
        totals.personalFouls += line.personalFouls;
      }
    }
    return totals;
  }

  void _startTimer() {
    if (!_canWrite) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final game = activeGame;
      if (game == null || !game.running || !mounted) return;
      var timeExpired = false;
      setState(() {
        if (game.remainingSeconds > 0) game.remainingSeconds--;
        if (game.remainingSeconds == 0) {
          game.running = false;
          timeExpired = true;
          _timer?.cancel();
        }
      });
      if (timeExpired) {
        _finishGame();
        return;
      }
      _save(syncCloud: game.remainingSeconds % 15 == 0);
    });
  }

  Future<void> _addPlayer(String name) async {
    if (!_canWrite) return;
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;
    setState(
      () => players.add(
        Player(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: cleanName,
        ),
      ),
    );
    await _save();
  }

  Future<void> _createGame(Game game) async {
    if (!_canWrite) return;
    setState(() => activeGame = game);
    await _save();
  }

  Future<void> _score(String team, String? playerId, int points) async {
    final game = activeGame;
    if (!_canWrite || game == null || game.finished || _finishingGame) return;
    if (_scoreLimitReached(game)) {
      await _finishGame();
      return;
    }
    var reachedTarget = false;
    setState(() {
      if (team == 'home') {
        game.homeScore += points;
      } else {
        game.awayScore += points;
      }
      if (playerId != null) {
        final line = game.lineFor(playerId);
        line.points += points;
        if (points == 3) line.threes++;
      }
      reachedTarget =
          game.mode == 'points' &&
          (game.homeScore >= game.target || game.awayScore >= game.target);
    });
    if (reachedTarget) {
      await _finishGame();
      return;
    }
    await _save();
  }

  bool _scoreLimitReached(Game game) =>
      game.mode == 'points' &&
      (game.homeScore >= game.target || game.awayScore >= game.target);

  Future<void> _adjustStat(String playerId, String stat, int amount) async {
    final game = activeGame;
    if (!_canWrite ||
        game == null ||
        game.finished ||
        _finishingGame ||
        _scoreLimitReached(game)) {
      return;
    }
    final team = game.homePlayers.contains(playerId) ? 'home' : 'away';
    setState(() {
      final line = game.lineFor(playerId);
      switch (stat) {
        case 'rebounds':
          line.rebounds = (line.rebounds + amount).clamp(0, 999).toInt();
        case 'assists':
          line.assists = (line.assists + amount).clamp(0, 999).toInt();
        case 'steals':
          line.steals = (line.steals + amount).clamp(0, 999).toInt();
        case 'turnovers':
          line.turnovers = (line.turnovers + amount).clamp(0, 999).toInt();
        case 'blocks':
          line.blocks = (line.blocks + amount).clamp(0, 999).toInt();
        case 'personalFouls':
          line.personalFouls =
              (line.personalFouls + amount).clamp(0, 999).toInt();
      }
    });
    if (stat == 'personalFouls' &&
        amount > 0 &&
        _teamFouls(game, team) >= _teamFoulLimit) {
      final messenger = _messengerKey.currentState;
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${team == 'home' ? game.home : game.away}: falta colectiva '
            '${_teamFouls(game, team)}. '
            'Desde la falta $_teamFoulLimit (incluida), hay tiros libres '
            'por cada falta personal.',
          ),
        ),
      );
    }
    await _save();
  }

  int _teamFouls(Game game, String team) {
    final ids = team == 'home' ? game.homePlayers : game.awayPlayers;
    return game.lines
        .where((line) => ids.contains(line.playerId))
        .fold(0, (total, line) => total + line.personalFouls);
  }

  Future<void> _finishGame() async {
    final game = activeGame;
    final leagueId = _selectedLeagueId;
    if (!_canWrite ||
        game == null ||
        game.finished ||
        _finishingGame ||
        !_cloudLoaded ||
        leagueId == null) {
      return;
    }
    _timer?.cancel();
    final activeGameId = game.id;
    game.ensureHistoryId();
    game.recordResultPlayers();
    _finishingGame = true;
    _finishError = null;
    if (mounted) setState(() {});
    final finishedData =
        Map<String, dynamic>.from(game.toJson())
          ..['running'] = false
          ..['finished'] = true;
    try {
      await _backend.finishGame(leagueId, finishedData, activeGameId);
      if (!mounted || _selectedLeagueId != leagueId) return;
      setState(() {
        game.running = false;
        game.finished = true;
        if (!games.any((savedGame) => savedGame.id == game.id)) {
          games.insert(0, game);
        }
        activeGame = null;
        _cloudError = null;
      });
      await _enqueuePersistence(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'games_$leagueId',
          jsonEncode(games.map((savedGame) => savedGame.toJson()).toList()),
        );
        await prefs.remove('activeGame_$leagueId');
      });
    } catch (error) {
      _finishError = firebaseAuthMessage(error);
      _reportCloudError(error);
    } finally {
      _finishingGame = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleClock() async {
    final game = activeGame;
    if (!_canWrite ||
        game == null ||
        game.finished ||
        game.remainingSeconds == 0) {
      return;
    }
    setState(() => game.running = !game.running);
    if (game.running) {
      _startTimer();
    } else {
      _timer?.cancel();
    }
    await _save();
  }

  Future<void> _adjustScore(
    String team,
    int amount, {
    String? playerId,
    bool correctThreeToTwo = false,
  }) async {
    final game = activeGame;
    if (!_canWrite ||
        game == null ||
        game.finished ||
        _finishingGame ||
        _scoreLimitReached(game)) {
      return;
    }
    var reachedTarget = false;
    var changed = true;
    setState(() {
      if (amount < 0) {
        if (playerId == null) {
          changed = false;
          return;
        }
        changed = game.removePoint(
          team,
          playerId: playerId,
          correctThreeToTwo: correctThreeToTwo,
        );
      } else {
        if (team == 'home') {
          game.homeScore = (game.homeScore + amount).clamp(0, 999).toInt();
        } else {
          game.awayScore = (game.awayScore + amount).clamp(0, 999).toInt();
        }
      }
      reachedTarget = _scoreLimitReached(game);
    });
    if (!changed) return;
    if (reachedTarget) {
      await _finishGame();
      return;
    }
    await _save();
  }

  Future<void> _choosePointRemoval(String team) async {
    if (!_canWrite) return;
    final game = activeGame;
    if (game == null) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final roster = team == 'home' ? game.homePlayers : game.awayPlayers;
    final removal =
        await showModalBottomSheet<({String playerId, bool correctThreeToTwo})>(
          context: overlayContext,
          backgroundColor: _surface,
          builder:
              (context) => SafeArea(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          '¿A quién quitarle 1 punto?',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      ...roster.map((id) {
                        final player = _player(id);
                        final line = game.lines.where(
                          (item) => item.playerId == id,
                        );
                        final points = line.isEmpty ? 0 : line.first.points;
                        final threes = line.isEmpty ? 0 : line.first.threes;
                        if (points <= 0) return const SizedBox.shrink();
                        return ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person),
                          ),
                          title: Text(player?.name ?? 'Jugador'),
                          subtitle: Text('PTS $points · 3PT $threes'),
                          onTap:
                              () => Navigator.pop(context, (
                                playerId: id,
                                correctThreeToTwo: false,
                              )),
                          trailing:
                              threes > 0 && points >= 3
                                  ? TextButton(
                                    onPressed:
                                        () => Navigator.pop(context, (
                                          playerId: id,
                                          correctThreeToTwo: true,
                                        )),
                                    child: const Text('3PT → 2PT'),
                                  )
                                  : null,
                        );
                      }),
                    ],
                  ),
                ),
              ),
        );
    if (removal == null || activeGame != game) return;
    await _adjustScore(
      team,
      -1,
      playerId: removal.playerId,
      correctThreeToTwo: removal.correctThreeToTwo,
    );
  }

  Future<void> _shareMemberDues(Player player) async {
    final message = buildMemberDuesWhatsAppMessage(
      leagueName: _selectedLeagueName,
      memberId: player.id,
      memberName: player.name,
      period: _selectedFinancePeriod,
      monthlyDues: _monthlyDues,
      received: _receivedForMember(player.id, _selectedFinancePeriod),
      payments:
          financeEntries.where((entry) => entry.memberId == player.id).toList(),
    );
    await _shareViaWhatsApp(message);
  }

  Future<void> _shareLeagueDues() async {
    final message = buildLeagueDuesWhatsAppMessage(
      leagueName: _selectedLeagueName,
      period: _selectedFinancePeriod,
      monthlyDues: _monthlyDues,
      members:
          players
              .map(
                (player) => (
                  name: player.name,
                  received: _receivedForMember(
                    player.id,
                    _selectedFinancePeriod,
                  ),
                ),
              )
              .toList(),
    );
    await _shareViaWhatsApp(message);
  }

  Future<void> _shareViaWhatsApp(String message) async {
    try {
      final opened = await launchUrl(
        whatsAppShareUri(message),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
        );
      }
    } catch (error) {
      if (mounted) {
        _messengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('No se pudo abrir WhatsApp: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      title: 'PizarraFe',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _orange,
          brightness: Brightness.dark,
          surface: _surface,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: _background,
          foregroundColor: Colors.white,
          centerTitle: false,
        ),
      ),
      home:
          !_localLoaded || !_authResolved
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _identity == null
              ? _AuthPage(backend: _backend)
              : _cloudError != null
              ? _cloudFailureScreen()
              : !_cloudLoaded
              ? _cloudLoadingScreen()
              : _profile == null
              ? _accountErrorScreen()
              : _selectedLeagueId == null
              ? _noLeagueScreen()
              : Scaffold(
                appBar: AppBar(
                  title: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'PIZARRAFE',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                      Text(
                        _selectedLeagueName,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 11,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    if (activeGame != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 14),
                        child: Chip(
                          avatar: const Icon(
                            Icons.circle,
                            size: 9,
                            color: _orange,
                          ),
                          label: const Text('EN JUEGO'),
                          backgroundColor: _surface,
                        ),
                      ),
                  ],
                ),
                body: IndexedStack(
                  index: _tab,
                  children: [
                    _home(),
                    _playersPage(),
                    _comparePage(),
                    _historyPage(),
                    _financePage(),
                    _accountPage(),
                  ],
                ),
                bottomNavigationBar: NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected:
                      (index) => setState(() => _tab = index),
                  backgroundColor: _surface,
                  indicatorColor: _orange.withValues(alpha: .18),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.sports_basketball_outlined),
                      selectedIcon: Icon(Icons.sports_basketball),
                      label: 'Pizarra',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.groups_outlined),
                      selectedIcon: Icon(Icons.groups),
                      label: 'Miembro',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.compare_arrows),
                      label: 'Comparar',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.emoji_events_outlined),
                      selectedIcon: Icon(Icons.emoji_events),
                      label: 'Historial',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.account_balance_wallet_outlined),
                      selectedIcon: Icon(Icons.account_balance_wallet),
                      label: 'Finanzas',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.manage_accounts_outlined),
                      selectedIcon: Icon(Icons.manage_accounts),
                      label: 'Cuenta',
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _cloudLoadingScreen() => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            const Text('Conectando con la liga...'),
            if (_cloudError != null) ...[
              const SizedBox(height: 12),
              Text(_cloudError!, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _cloudFailureScreen() => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: _orange, size: 42),
            const SizedBox(height: 14),
            const Text(
              'No se pudo sincronizar la liga',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(_cloudError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _signOut,
              child: const Text('Cerrar sesión'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _accountErrorScreen() => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_circle_outlined, color: _orange, size: 42),
            const SizedBox(height: 14),
            const Text(
              'No se encontró el perfil de esta cuenta.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _signOut,
              child: const Text('Cerrar sesión'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _accountPage() {
    final username = _profile?['username'] as String? ?? 'Usuario';
    final role = _isOwner ? 'owner' : _selectedLeagueRole ?? 'viewer';
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        const Text(
          'Mi cuenta',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: Color(0x33FF8A3D),
                child: Icon(Icons.person, color: _orange),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      username,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      role == 'owner'
                          ? 'Propietario · Administrador'
                          : role == 'admin'
                          ? 'Administrador'
                          : 'Lector · Solo consulta',
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'MIS LIGAS',
          style: TextStyle(
            color: _muted,
            fontSize: 12,
            letterSpacing: 1,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectedLeagueId,
          decoration: const InputDecoration(
            labelText: 'Liga activa',
            border: OutlineInputBorder(),
          ),
          items:
              _availableLeagues
                  .map(
                    (league) => DropdownMenuItem<String>(
                      value: league['id'] as String,
                      child: Text(league['name'] as String? ?? 'Liga'),
                    ),
                  )
                  .toList(),
          onChanged: _selectLeague,
        ),
        if (_isOwner) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _createLeagueFlow,
            icon: const Icon(Icons.add_business),
            label: const Text('Crear liga e invitar administrador'),
          ),
          OutlinedButton.icon(
            onPressed: _migrateLegacyUsers,
            icon: const Icon(Icons.group_add_outlined),
            label: const Text('Asignar cuentas existentes a Liga La Fe'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Esta asignación conserva sus nombres y permisos anteriores.',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
          ),
        ],
        if (_selectedLeagueId != null && _canWrite) ...[
          const SizedBox(height: 24),
          const Text(
            'INVITACIONES Y MIEMBROS',
            style: TextStyle(
              color: _muted,
              fontSize: 12,
              letterSpacing: 1,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _createInvitationFlow('viewer'),
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Crear invitación para miembro'),
          ),
          if (_isOwner)
            OutlinedButton.icon(
              onPressed: () => _createInvitationFlow('admin'),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Invitar administrador a esta liga'),
            ),
          const SizedBox(height: 8),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _backend.watchLeagueMembers(_selectedLeagueId!),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text(
                  'No se pudieron cargar los miembros: ${snapshot.error}',
                  style: const TextStyle(color: _orange),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return Container(
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children:
                      snapshot.data!.map((user) {
                        final userId = user['uid'] as String;
                        final userRole = user['role'] as String? ?? 'viewer';
                        final isSelf = userId == _identity?.uid;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                userRole == 'admin'
                                    ? _orange.withValues(alpha: .18)
                                    : _background,
                            child: Icon(
                              userRole == 'owner'
                                  ? Icons.verified_user
                                  : userRole == 'admin'
                                  ? Icons.admin_panel_settings
                                  : Icons.person_outline,
                              color: userRole == 'viewer' ? _muted : _orange,
                            ),
                          ),
                          title: Text(user['username'] as String? ?? 'Usuario'),
                          subtitle: Text(
                            userRole == 'admin'
                                ? 'Administrador'
                                : 'Solo lectura',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                          trailing:
                              _isOwner && !isSelf
                                  ? DropdownButton<String>(
                                    value: userRole,
                                    onChanged: (value) {
                                      if (value != null) {
                                        _changeUserRole(userId, value);
                                      }
                                    },
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'viewer',
                                        child: Text('Lector'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'admin',
                                        child: Text('Administrador'),
                                      ),
                                    ],
                                  )
                                  : null,
                        );
                      }).toList(),
                ),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Solo el propietario puede cambiar los permisos de las cuentas.',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _redeemInvitationFlow,
          icon: const Icon(Icons.vpn_key_outlined),
          label: const Text('Unirme a otra liga con un código'),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _signOut,
          icon: const Icon(Icons.logout),
          label: const Text('Cerrar sesión'),
        ),
      ],
    );
  }

  Future<void> _changeUserRole(String uid, String role) async {
    try {
      await _backend.changeRole(_selectedLeagueId!, uid, role);
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Widget _noLeagueScreen() => Scaffold(
    appBar: AppBar(title: const Text('PIZARRAFE')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.groups_outlined, size: 52, color: _orange),
              const SizedBox(height: 14),
              const Text(
                'Todavía no perteneces a una liga',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Solicita una invitación al administrador de tu liga para acceder a sus partidos y estadísticas.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _redeemInvitationFlow,
                icon: const Icon(Icons.vpn_key_outlined),
                label: const Text('Ingresar código de invitación'),
              ),
              TextButton(
                onPressed: _signOut,
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _createLeagueFlow() async {
    var leagueNameInput = '';
    final name = await showDialog<String>(
      context: _navigatorKey.currentContext!,
      builder:
          (context) => AlertDialog(
            title: const Text('Crear liga'),
            content: TextField(
              autofocus: true,
              maxLength: 60,
              onChanged: (value) => leagueNameInput = value,
              decoration: const InputDecoration(
                labelText: 'Nombre de la liga',
                hintText: 'Ej. Liga del Este',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, leagueNameInput),
                child: const Text('Crear'),
              ),
            ],
          ),
    );
    if (name == null) return;
    try {
      final leagueId = await _backend.createLeague(name);
      final inviteCode = await _backend.createInvitation(leagueId, 'admin');
      final newLeague = {'id': leagueId, 'name': name.trim(), 'role': 'owner'};
      setState(() {
        _availableLeagues = [
          ..._availableLeagues.where((item) => item['id'] != leagueId),
          newLeague,
        ];
      });
      _selectLeague(leagueId);
      await _showInviteCode(
        inviteCode,
        'Envía este código a quien será administrador de ${name.trim()}.',
      );
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Future<void> _createInvitationFlow(String role) async {
    final leagueId = _selectedLeagueId;
    if (leagueId == null) return;
    try {
      final code = await _backend.createInvitation(leagueId, role);
      final leagueName =
          _availableLeagues
              .where((league) => league['id'] == leagueId)
              .map((league) => league['name'] as String? ?? 'la liga')
              .first;
      await _showInviteCode(
        code,
        role == 'admin'
            ? 'Código de administrador para $leagueName.'
            : 'Código para un miembro de $leagueName.',
      );
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Future<void> _showInviteCode(String code, String description) async {
    await showDialog<void>(
      context: _navigatorKey.currentContext!,
      builder:
          (context) => AlertDialog(
            title: const Text('Invitación creada'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description),
                const SizedBox(height: 12),
                SelectableText(
                  code,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Es de un solo uso. Compártelo únicamente con la persona indicada.',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Listo'),
              ),
            ],
          ),
    );
  }

  Future<void> _redeemInvitationFlow() async {
    var codeInput = '';
    final code = await showDialog<String>(
      context: _navigatorKey.currentContext!,
      builder:
          (context) => AlertDialog(
            title: const Text('Usar invitación'),
            content: TextField(
              textCapitalization: TextCapitalization.characters,
              onChanged: (value) => codeInput = value,
              decoration: const InputDecoration(
                labelText: 'Código de invitación',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, codeInput),
                child: const Text('Unirme'),
              ),
            ],
          ),
    );
    if (code == null) return;
    try {
      await _backend.redeemInvitation(code);
      if (mounted) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Te uniste a la liga correctamente.')),
        );
      }
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Future<void> _migrateLegacyUsers() async {
    final confirmed = await showDialog<bool>(
      context: _navigatorKey.currentContext!,
      builder:
          (context) => AlertDialog(
            title: const Text('Asignar cuentas existentes'),
            content: const Text(
              'Se asignarán a Liga La Fe todas las cuentas actuales, conservando el permiso de administrador de quienes ya lo tenían. ¿Continuar?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Asignar'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await _backend.migrateLegacyUsers();
      if (mounted) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Cuentas existentes asignadas a Liga La Fe.'),
          ),
        );
      }
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Future<void> _signOut() async {
    try {
      await _backend.signOut();
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Widget _home() {
    final game = activeGame;
    if (game != null) return _liveGame(game);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF202C47), Color(0xFF151D31)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: .07)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'LA CANCHA ES TUYA',
                style: TextStyle(
                  color: _orange,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tu liga. Cada jugada.\nEn una sola pizarra.',
                style: TextStyle(
                  fontSize: 26,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed:
                    !_canWrite
                        ? () => setState(() => _tab = 2)
                        : players.length < 10
                        ? () => setState(() => _tab = 1)
                        : _showNewGame,
                icon: const Icon(Icons.add),
                label: Text(
                  !_canWrite
                      ? 'Ver estadísticas'
                      : players.length < 10
                      ? 'Registra los 10 jugadores'
                      : 'Iniciar partido',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _orange,
                  foregroundColor: const Color(0xFF241308),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                ),
              ),
              if (_canWrite && players.length < 10)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'Un partido necesita 5 jugadores por equipo. Registra al menos 10 jugadores.',
                    style: TextStyle(color: _muted),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'PARTIDOS',
                '${games.length}',
                Icons.sports_basketball,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'JUGADORES',
                '${players.length}',
                Icons.groups,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'PUNTOS',
                '${games.fold<int>(0, (n, g) => n + g.homeScore + g.awayScore)}',
                Icons.bolt,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _sectionTitle(
          'ÚLTIMOS RESULTADOS',
          'Ver todos',
          () => setState(() => _tab = 3),
        ),
        const SizedBox(height: 10),
        if (games.isEmpty)
          _emptyCard(
            'Aún no hay partidos',
            'Cuando termine tu primer juego, aparecerá aquí.',
          )
        else
          ...games.take(4).map(_gameCard),
      ],
    );
  }

  Widget _summaryCard(String title, String value, IconData icon) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white.withValues(alpha: .05)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: _orange),
        const SizedBox(height: 12),
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        Text(
          title,
          style: const TextStyle(
            fontSize: 10,
            color: _muted,
            letterSpacing: .6,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );

  Widget _liveGame(Game game) {
    final landscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final clock =
        '${(game.remainingSeconds ~/ 60).toString().padLeft(2, '0')}:${(game.remainingSeconds % 60).toString().padLeft(2, '0')}';
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 96),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                game.mode == 'points'
                    ? 'A ${game.target} PUNTOS'
                    : 'PARTIDO CON TIEMPO',
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              Text(
                game.mode == 'points' ? 'PRIMERO A ${game.target}' : 'RELOJ',
                style: const TextStyle(
                  color: _orange,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: .07)),
            ),
            child: Row(
              children: [
                Expanded(child: _scorePanel(game, 'home', _blue)),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    game.mode == 'time' ? clock : 'VS',
                    style: TextStyle(
                      color: game.mode == 'time' ? Colors.white : _muted,
                      fontSize: game.mode == 'time' ? 23 : 14,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(child: _scorePanel(game, 'away', _orange)),
              ],
            ),
          ),
          if (game.mode == 'time') ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        !_canWrite || game.remainingSeconds == 0
                            ? null
                            : _toggleClock,
                    icon: Icon(game.running ? Icons.pause : Icons.play_arrow),
                    label: Text(
                      game.running ? 'Pausar reloj' : 'Iniciar reloj',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${game.durationSeconds ~/ 60} min',
                  style: const TextStyle(color: _muted),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ESTADÍSTICAS EN VIVO',
                  style: TextStyle(
                    color: _muted,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_canWrite)
                TextButton.icon(
                  onPressed:
                      _finishingGame
                          ? null
                          : _finishError == null
                          ? _confirmFinish
                          : _finishGame,
                  icon: Icon(
                    _finishingGame
                        ? Icons.cloud_upload_outlined
                        : _finishError == null
                        ? Icons.flag_outlined
                        : Icons.refresh,
                    size: 17,
                  ),
                  label: Text(
                    _finishingGame
                        ? 'Guardando resultado...'
                        : _finishError == null
                        ? 'Finalizar'
                        : 'Reintentar guardado',
                  ),
                ),
            ],
          ),
          if (_finishError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'No se pudo guardar el resultado: $_finishError',
                style: const TextStyle(color: _orange, fontSize: 12),
              ),
            ),
          if (_finishingGame) const LinearProgressIndicator(),
          if (landscape)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _teamStats(game, 'home', _blue)),
                const SizedBox(width: 10),
                Expanded(child: _teamStats(game, 'away', _orange)),
              ],
            )
          else
            Column(
              children: [
                _teamStats(game, 'home', _blue),
                const SizedBox(height: 10),
                _teamStats(game, 'away', _orange),
              ],
            ),
        ],
      ),
    );
  }

  Widget _scorePanel(Game game, String team, Color color) {
    final isHome = team == 'home';
    final name = isHome ? game.home : game.away;
    final score = isHome ? game.homeScore : game.awayScore;
    final roster = game.activePlayersFor(team);
    return Column(
      children: [
        Text(
          name.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 14,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$score',
          style: const TextStyle(
            fontSize: 60,
            fontWeight: FontWeight.w900,
            height: 1,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          children: [
            _scoreButton(
              team,
              roster,
              1,
              color,
              enabled: !_finishingGame && !_scoreLimitReached(game),
            ),
            _scoreButton(
              team,
              roster,
              2,
              color,
              enabled: !_finishingGame && !_scoreLimitReached(game),
            ),
            _scoreButton(
              team,
              roster,
              3,
              color,
              enabled: !_finishingGame && !_scoreLimitReached(game),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Restar punto',
              onPressed:
                  _canWrite &&
                          score > 0 &&
                          !_finishingGame &&
                          !_scoreLimitReached(game)
                      ? () => _choosePointRemoval(team)
                      : null,
              icon: const Icon(Icons.remove_circle_outline, size: 19),
            ),
            const Text(
              'ajustar',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Sumar punto',
              onPressed:
                  _canWrite && !_finishingGame && !_scoreLimitReached(game)
                      ? () => _chooseScorer(team, 1, allowUnassigned: false)
                      : null,
              icon: const Icon(Icons.add_circle_outline, size: 19),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 3,
          runSpacing: 2,
          children: [
            _quickStatButton(team, 'assists', 'AST'),
            _quickStatButton(team, 'rebounds', 'REB'),
            _quickStatButton(team, 'steals', 'ROB'),
            _quickStatButton(team, 'turnovers', 'TO'),
            _quickStatButton(team, 'blocks', 'BLK'),
            _quickStatButton(team, 'personalFouls', 'FP'),
          ],
        ),
      ],
    );
  }

  Widget _quickStatButton(String team, String stat, String label) => SizedBox(
    height: 28,
    child: Tooltip(
      message: 'Anotar $label',
      child: OutlinedButton(
        onPressed:
            !_canWrite || _finishingGame || _scoreLimitReached(activeGame!)
                ? null
                : () => _chooseStatPlayer(team, stat, label),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          side: BorderSide(color: Colors.white.withValues(alpha: .14)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 10)),
      ),
    ),
  );

  Widget _scoreButton(
    String team,
    List<String> roster,
    int points,
    Color color, {
    bool enabled = true,
  }) {
    return SizedBox(
      height: 35,
      child: FilledButton(
        onPressed:
            !_canWrite || !enabled || roster.isEmpty
                ? null
                : () => _chooseScorer(team, points),
        style: FilledButton.styleFrom(
          backgroundColor: color.withValues(alpha: .16),
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          '+$points',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Future<void> _chooseScorer(
    String team,
    int points, {
    bool allowUnassigned = true,
  }) async {
    if (!_canWrite) return;
    final game = activeGame;
    if (game == null) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final roster = game.activePlayersFor(team);
    final selected = await showModalBottomSheet<String>(
      context: overlayContext,
      backgroundColor: _surface,
      builder:
          (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      '¿Quién anotó $points ${points == 1 ? 'punto' : 'puntos'}?',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  ...roster.map((id) {
                    final player = _player(id);
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(player?.name ?? 'Jugador'),
                      onTap: () => Navigator.pop(context, id),
                    );
                  }),
                  if (allowUnassigned)
                    ListTile(
                      leading: const Icon(
                        Icons.person_off_outlined,
                        color: _muted,
                      ),
                      title: const Text(
                        'Punto sin atribuir',
                        style: TextStyle(color: _muted),
                      ),
                      onTap: () => Navigator.pop(context, ''),
                    ),
                ],
              ),
            ),
          ),
    );
    if (selected == null) return;
    await _score(team, selected.isEmpty ? null : selected, points);
  }

  Future<void> _chooseStatPlayer(String team, String stat, String label) async {
    if (!_canWrite) return;
    final game = activeGame;
    if (game == null) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final selected = await showModalBottomSheet<String>(
      context: overlayContext,
      backgroundColor: _surface,
      builder:
          (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      '¿A quién anotar $label?',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  ...game.activePlayersFor(team).map((id) {
                    final player = _player(id);
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(player?.name ?? 'Jugador'),
                      onTap: () => Navigator.pop(context, id),
                    );
                  }),
                ],
              ),
            ),
          ),
    );
    if (selected == null || activeGame != game) return;
    await _adjustStat(selected, stat, 1);
  }

  Future<void> _replacePlayer(String team, String outgoingId) async {
    if (!_canWrite || activeGame == null) return;
    final game = activeGame!;
    final teamPlayers = team == 'home' ? game.homePlayers : game.awayPlayers;
    final opponents = team == 'home' ? game.awayPlayers : game.homePlayers;
    final candidates =
        players
            .where(
              (player) =>
                  player.id != outgoingId &&
                  !opponents.contains(player.id) &&
                  (!teamPlayers.contains(player.id) ||
                      !game.activePlayersFor(team).contains(player.id)),
            )
            .toList();
    if (candidates.isEmpty) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('No hay sustitutos disponibles fuera del otro equipo.'),
        ),
      );
      return;
    }
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final incomingId = await showModalBottomSheet<String>(
      context: overlayContext,
      backgroundColor: _surface,
      builder:
          (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      'Sustituir a ${_player(outgoingId)?.name ?? 'Jugador'}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  ...candidates.map(
                    (player) => ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_add),
                      ),
                      title: Text(player.name),
                      onTap: () => Navigator.pop(context, player.id),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
    if (incomingId == null || activeGame != game) return;
    if (!game.substitute(team, outgoingId, incomingId)) {
      throw StateError('No se pudo completar la sustitución.');
    }
    setState(() {});
    await _save();
  }

  Widget _teamStats(Game game, String team, Color color) {
    final ids = team == 'home' ? game.homePlayers : game.awayPlayers;
    final name = team == 'home' ? game.home : game.away;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (ids.isEmpty)
            const Text(
              'Sin jugadores asignados',
              style: TextStyle(color: _muted),
            )
          else
            Text(
              'Faltas de equipo: ${_teamFouls(game, team)} / $_teamFoulLimit',
              style: TextStyle(
                color:
                    _teamFouls(game, team) >= _teamFoulLimit ? _orange : _muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          const SizedBox(height: 6),
          ...ids.map((id) => _playerLiveRow(id, team)),
        ],
      ),
    );
  }

  Widget _playerLiveRow(String id, String team) {
    final player = _player(id);
    final line = activeGame!.lineFor(id);
    final active = activeGame!.activePlayersFor(team).contains(id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${player?.name ?? 'Jugador'}${active ? '' : ' · En banca'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (active && _canWrite)
                IconButton(
                  tooltip: 'Sustituir ${player?.name ?? 'jugador'}',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed:
                      _finishingGame ? null : () => _replacePlayer(team, id),
                  icon: const Icon(Icons.swap_horiz, size: 19),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              _statValue('PTS', line.points),
              _statControl(id, 'rebounds', 'REB', line.rebounds),
              _statControl(id, 'assists', 'AST', line.assists),
              _statValue('3PT', line.threes),
              _statControl(id, 'steals', 'ROB', line.steals),
              _statControl(id, 'turnovers', 'TO', line.turnovers),
              _statControl(id, 'blocks', 'BLK', line.blocks),
              _statControl(id, 'personalFouls', 'FP', line.personalFouls),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statValue(String label, int value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
    decoration: BoxDecoration(
      color: _background,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      '$label $value',
      style: const TextStyle(fontSize: 10, color: _muted),
    ),
  );

  Widget _statControl(String id, String stat, String label, int value) =>
      Container(
        decoration: BoxDecoration(
          color: _background,
          borderRadius: BorderRadius.circular(9),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              padding: EdgeInsets.zero,
              tooltip: 'Restar $label',
              onPressed:
                  !_canWrite ||
                          value == 0 ||
                          _finishingGame ||
                          activeGame == null ||
                          _scoreLimitReached(activeGame!)
                      ? null
                      : () => _adjustStat(id, stat, -1),
              icon: const Icon(Icons.remove, size: 15),
            ),
            Text(
              '$label $value',
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              padding: EdgeInsets.zero,
              tooltip: 'Sumar $label',
              onPressed:
                  _canWrite &&
                          !_finishingGame &&
                          activeGame != null &&
                          !_scoreLimitReached(activeGame!)
                      ? () => _adjustStat(id, stat, 1)
                      : null,
              icon: const Icon(Icons.add, size: 15),
            ),
          ],
        ),
      );

  void _confirmFinish() {
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    showDialog<void>(
      context: overlayContext,
      builder:
          (context) => AlertDialog(
            title: const Text('¿Finalizar partido?'),
            content: const Text(
              'Puedes guardar el resultado en el historial o salir sin guardar esta partida.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Seguir jugando'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: _orange),
                onPressed: () {
                  Navigator.pop(context);
                  _confirmDiscardGame();
                },
                child: const Text('Salir sin guardar'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _finishGame();
                },
                child: const Text('Finalizar'),
              ),
            ],
          ),
    );
  }

  void _confirmDiscardGame() {
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    showDialog<bool>(
      context: overlayContext,
      builder:
          (context) => AlertDialog(
            title: const Text('¿Descartar esta partida?'),
            content: const Text(
              'El marcador y las estadísticas de este juego se eliminarán y no aparecerán en el historial.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _orange),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Descartar partida'),
              ),
            ],
          ),
    ).then((confirmed) {
      if (confirmed == true) _discardActiveGame();
    });
  }

  Future<void> _discardActiveGame() async {
    if (!_canWrite || activeGame == null) return;
    final game = activeGame!;
    final leagueId = _selectedLeagueId;
    if (leagueId == null) return;
    _timer?.cancel();
    setState(() => activeGame = null);
    try {
      await _backend.clearActiveGame(leagueId, game.id);
      await _save();
    } catch (error) {
      setState(() => activeGame = game);
      _reportCloudError(error, fatal: true);
    }
  }

  Future<void> _showNewGame() async {
    if (!_canWrite) return;
    if (players.length < 10) {
      setState(() => _tab = 1);
      _messengerKey.currentState!.showSnackBar(
        const SnackBar(
          content: Text(
            'Registra al menos 10 jugadores para armar dos equipos de 5.',
          ),
        ),
      );
      return;
    }
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final game = await showModalBottomSheet<Game>(
      context: overlayContext,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder: (context) => _NewGameSheet(players: players),
    );
    if (game != null) await _createGame(game);
  }

  Widget _playersPage() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Plantel de la liga',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              if (_canWrite)
                FilledButton.icon(
                  onPressed: _showAddPlayer,
                  icon: const Icon(Icons.person_add_alt_1, size: 18),
                  label: const Text('Agregar'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _orange,
                    foregroundColor: const Color(0xFF241308),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child:
              players.isEmpty
                  ? _emptyCard(
                    _canWrite
                        ? 'Registra tu primer jugador'
                        : 'Todavía no hay jugadores',
                    _canWrite
                        ? 'El plantel sirve para armar partidos y registrar estadísticas.'
                        : 'Los jugadores de la liga aparecerán aquí.',
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                    itemCount: players.length,
                    itemBuilder: (context, index) {
                      final player = players[index];
                      final total = totalsFor(player.id);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: _blue.withValues(alpha: .15),
                            child: Text(
                              player.name.substring(0, 1).toUpperCase(),
                              style: const TextStyle(
                                color: _blue,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          title: Text(
                            player.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            '${total.games} PJ  ·  ${total.wins} G  ·  ${total.losses} P'
                            '   |   ${total.points} pts · ${total.rebounds} reb · ${total.assists} ast · ${total.steals} ROB · ${total.turnovers} TO · ${total.blocks} BLK · ${total.personalFouls} FP',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                          trailing:
                              _canWrite
                                  ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: 'Editar nombre',
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          color: _muted,
                                        ),
                                        onPressed: () => _editPlayer(player),
                                      ),
                                      IconButton(
                                        tooltip: 'Eliminar jugador',
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: _muted,
                                        ),
                                        onPressed:
                                            () => _confirmDeletePlayer(player),
                                      ),
                                    ],
                                  )
                                  : null,
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Future<void> _showAddPlayer() async {
    if (!_canWrite) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final name = await showModalBottomSheet<String>(
      context: overlayContext,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder: (_) => const _AddPlayerSheet(),
    );
    if (name != null) await _addPlayer(name);
  }

  Future<void> _editPlayer(Player player) async {
    if (!_canWrite) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final name = await showModalBottomSheet<String>(
      context: overlayContext,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder: (_) => _AddPlayerSheet(initialName: player.name, editing: true),
    );
    if (name == null || name == player.name) return;
    setState(() {
      final index = players.indexWhere((item) => item.id == player.id);
      if (index >= 0) {
        players[index] = Player(id: player.id, name: name);
      }
    });
    await _save();
  }

  Future<void> _confirmDeletePlayer(Player player) async {
    if (!_canWrite) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final confirmed = await showDialog<bool>(
      context: overlayContext,
      builder:
          (context) => AlertDialog(
            title: const Text('Eliminar jugador'),
            content: Text(
              '¿Eliminar a ${player.name} del plantel? Los partidos guardados conservarán sus datos.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Eliminar'),
              ),
            ],
          ),
    );
    if (confirmed == true) {
      try {
        await _backend.deletePlayer(_selectedLeagueId!, player.id);
      } catch (error) {
        _reportCloudError(error);
        return;
      }
      setState(() => players.removeWhere((item) => item.id == player.id));
      await _save();
    }
  }

  Widget _comparePage() {
    if (players.isEmpty) {
      return _emptyCard(
        'Comparaciones de la liga',
        'Agrega jugadores y registra partidos para comparar sus resultados.',
      );
    }
    return _CompareView(
      players: players,
      totalsFor: totalsFor,
      games: games,
      playerName: (id) => _player(id)?.name ?? 'Jugador',
    );
  }

  Widget _historyPage() =>
      games.isEmpty
          ? _emptyCard(
            'Sin resultados todavía',
            'Los partidos finalizados se guardan automáticamente aquí.',
          )
          : ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Resultados guardados',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              ...games.map(_gameCard),
            ],
          );

  int _receivedForMember(String memberId, String period) => financeEntries
      .where(
        (entry) =>
            entry.kind == 'dues' &&
            entry.memberId == memberId &&
            entry.period == period,
      )
      .fold(0, (total, entry) => total + entry.amount);

  int _receivedForContribution(String period) => financeEntries
      .where(
        (entry) =>
            entry.kind == 'pledge' &&
            (entry.memberId == _leagueContributionId ||
                (entry.memberId == _legacyCarlosContributionId &&
                    _contributionName.toLowerCase() == 'carlos figuereo')) &&
            entry.period == period,
      )
      .fold(0, (total, entry) => total + entry.amount);

  Future<void> _editFinanceSettings() async {
    if (!_canWrite || _selectedLeagueId == null) return;
    var amountText = '$_monthlyDues';
    var contributionName = _contributionName;
    var teamFoulLimitText = '$_teamFoulLimit';
    String? validationError;
    String? foulLimitValidationError;
    final settings = await showDialog<(int, String, int)>(
      context: _navigatorKey.currentContext!,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Configuración de liga'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          initialValue: amountText,
                          keyboardType: TextInputType.number,
                          onChanged: (value) => amountText = value,
                          decoration: InputDecoration(
                            labelText: 'Cuota mensual por jugador',
                            prefixText: 'RD\$ ',
                            errorText: validationError,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          initialValue: contributionName,
                          maxLength: 60,
                          textCapitalization: TextCapitalization.words,
                          onChanged: (value) => contributionName = value,
                          decoration: const InputDecoration(
                            labelText: 'Aportante fijo (opcional)',
                            hintText: 'En blanco si no hay aportante',
                            helperText:
                                'El aporte comprometido es de RD\$2,000 al mes.',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue: teamFoulLimitText,
                          keyboardType: TextInputType.number,
                          onChanged: (value) => teamFoulLimitText = value,
                          decoration: InputDecoration(
                            labelText: 'Límite de faltas de equipo',
                            helperText:
                                'Avisar por cada falta personal desde este número.',
                            errorText: foulLimitValidationError,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Los cambios de cuota aplican a saldos futuros y no modifican movimientos registrados.',
                          style: TextStyle(color: _muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancelar'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final value = int.tryParse(amountText.trim());
                        final foulLimit = int.tryParse(
                          teamFoulLimitText.trim(),
                        );
                        if (value == null || value < 1 || value > 100000000) {
                          setDialogState(
                            () =>
                                validationError =
                                    'Escribe un monto entre RD\$1 y RD\$100,000,000.',
                          );
                          return;
                        }
                        if (foulLimit == null ||
                            foulLimit < 1 ||
                            foulLimit > 100) {
                          setDialogState(
                            () =>
                                foulLimitValidationError =
                                    'Escribe un límite entre 1 y 100.',
                          );
                          return;
                        }
                        Navigator.pop(context, (
                          value,
                          contributionName,
                          foulLimit,
                        ));
                      },
                      child: const Text('Guardar'),
                    ),
                  ],
                ),
          ),
    );
    if (settings == null) return;
    final leagueId = _selectedLeagueId;
    if (leagueId == null) return;
    final foulLimitChanged = settings.$3 != _teamFoulLimit;
    try {
      await _backend.updateFinanceSettings(
        leagueId,
        settings.$1,
        settings.$2,
        foulLimitChanged ? settings.$3 : null,
      );
      if (!mounted || _selectedLeagueId != leagueId) return;
      setState(() {
        _availableLeagues = [
          for (final league in _availableLeagues)
            if (league['id'] == leagueId)
              {
                ...league,
                'monthlyDues': settings.$1,
                'contributionName': settings.$2.trim(),
                if (foulLimitChanged) 'teamFoulLimit': settings.$3,
              }
            else
              league,
        ];
      });
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Future<void> _addFinanceEntry(String kind) async {
    if (!_canWrite) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final entry = await showModalBottomSheet<FinanceEntry>(
      context: overlayContext,
      isScrollControlled: true,
      backgroundColor: _surface,
      builder:
          (_) => _FinanceEntrySheet(
            kind: kind,
            players: players,
            monthlyDues: _monthlyDues,
            period: _selectedFinancePeriod,
            financeEntries: financeEntries,
            contributionName: _contributionName,
            contributionReceived: _receivedForContribution(
              _selectedFinancePeriod,
            ),
          ),
    );
    if (entry == null) return;
    try {
      await _backend.addFinanceEntry(_selectedLeagueId!, entry.toJson());
      if (!mounted) return;
      setState(() {
        if (entry.kind == 'dues') {
          _selectedFinancePeriod = entry.period;
        }
        financeEntries = [
          entry,
          ...financeEntries.where((item) => item.id != entry.id),
        ]..sort((a, b) => b.date.compareTo(a.date));
      });
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Widget _financePage() {
    final periodEntries = financeEntries.where(
      (entry) => entry.period == _selectedFinancePeriod,
    );
    final totalIncome = periodEntries
        .where((entry) => entry.isIncome)
        .fold(0, (total, entry) => total + entry.amount);
    final totalExpenses = periodEntries
        .where((entry) => entry.isExpense)
        .fold(0, (total, entry) => total + entry.amount);
    final courtPayments = periodEntries
        .where((entry) => entry.isExpense && entry.category == 'maintenance')
        .fold(0, (total, entry) => total + entry.amount);
    final duesExpected = players.length * _monthlyDues;
    final duesReceived = players.fold(
      0,
      (total, player) =>
          total + _receivedForMember(player.id, _selectedFinancePeriod),
    );
    final contributionReceived = _receivedForContribution(
      _selectedFinancePeriod,
    );
    final monthChoices = financePeriodChoices(DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Finanzas de la liga',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            if (_canWrite)
              IconButton(
                tooltip: 'Configuración de finanzas',
                onPressed: _editFinanceSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: DropdownButton<String>(
            value: _selectedFinancePeriod,
            underline: const SizedBox.shrink(),
            items:
                monthChoices
                    .map(
                      (period) => DropdownMenuItem(
                        value: period,
                        child: Text(financePeriodLabel(period)),
                      ),
                    )
                    .toList(),
            onChanged: (period) {
              if (period != null) {
                setState(() => _selectedFinancePeriod = period);
              }
            },
          ),
        ),
        const SizedBox(height: 12),
        if (_canWrite)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _addFinanceEntry('visits'),
                icon: const Icon(Icons.sports_basketball_outlined),
                label: const Text('Registrar pago de VISITAS'),
                style: FilledButton.styleFrom(backgroundColor: _orange),
              ),
              FilledButton.icon(
                onPressed: () => _addFinanceEntry('dues'),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Registrar cuota'),
                style: FilledButton.styleFrom(backgroundColor: _blue),
              ),
              if (_contributionName.isNotEmpty)
                FilledButton.icon(
                  onPressed: () => _addFinanceEntry('pledge'),
                  icon: const Icon(Icons.volunteer_activism),
                  label: Text('Aporte de $_contributionName'),
                  style: FilledButton.styleFrom(backgroundColor: _blue),
                ),
              FilledButton.icon(
                onPressed: () => _addFinanceEntry('expense'),
                icon: const Icon(Icons.receipt_long),
                label: const Text('Registrar gasto'),
                style: FilledButton.styleFrom(backgroundColor: _orange),
              ),
            ],
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'INGRESOS',
                formatPesos(totalIncome),
                Icons.south_west,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _summaryCard(
                'GASTOS',
                formatPesos(totalExpenses),
                Icons.north_east,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _summaryCard(
                'BALANCE',
                formatPesos(totalIncome - totalExpenses),
                Icons.account_balance_wallet,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _financeHeading('RESUMEN DE PAGOS DEL MES'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'DE MIEMBROS',
                formatPesos(duesReceived),
                Icons.groups_outlined,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _summaryCard(
                'A DUEÑOS DE CANCHA',
                formatPesos(courtPayments),
                Icons.sports_basketball_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Cuotas: ${formatPesos(duesReceived)} recibidos de ${formatPesos(duesExpected)} esperados',
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        if (players.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _shareLeagueDues,
              icon: const Icon(Icons.chat_outlined),
              label: const Text('Compartir pagos por WhatsApp'),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _financeHeading(
          'CUOTAS MENSUALES · ${formatPesos(_monthlyDues)} POR JUGADOR',
        ),
        const SizedBox(height: 8),
        if (players.isEmpty)
          _emptyCard(
            'No hay miembros registrados',
            'Agrega los miembros al plantel para controlar sus cuotas.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children:
                  players.map((player) {
                    final received = _receivedForMember(
                      player.id,
                      _selectedFinancePeriod,
                    );
                    final pending = (_monthlyDues - received).clamp(
                      0,
                      _monthlyDues,
                    );
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            pending == 0
                                ? _blue.withValues(alpha: .16)
                                : _orange.withValues(alpha: .16),
                        child: Icon(
                          pending == 0 ? Icons.check : Icons.person_outline,
                          color: pending == 0 ? _blue : _orange,
                        ),
                      ),
                      title: Text(player.name),
                      subtitle: Text(
                        'Abonado ${formatPesos(received)} de ${formatPesos(_monthlyDues)}'
                        '${received > _monthlyDues ? ' · Excedente ${formatPesos(received - _monthlyDues)}' : ''}',
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            pending == 0
                                ? 'Completa'
                                : 'Debe ${formatPesos(pending)}',
                            style: TextStyle(
                              color: pending == 0 ? _blue : _orange,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Enviar estado por WhatsApp',
                            onPressed: () => _shareMemberDues(player),
                            icon: const Icon(Icons.chat_outlined, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    );
                  }).toList(),
            ),
          ),
        const SizedBox(height: 18),
        if (_contributionName.isNotEmpty) ...[
          _financeHeading(
            'APORTE COMPROMETIDO · ${_contributionName.toUpperCase()}',
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0x3354B6FF),
                child: Icon(Icons.volunteer_activism, color: _blue),
              ),
              title: Text('Aporte mensual de $_contributionName'),
              subtitle: Text(
                'Recibido ${formatPesos(contributionReceived)} de ${formatPesos(_contributionPledge)}',
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
              trailing: Text(
                contributionReceived >= _contributionPledge
                    ? 'Completo'
                    : 'Pendiente ${formatPesos(_contributionPledge - contributionReceived)}',
                style: TextStyle(
                  color:
                      contributionReceived >= _contributionPledge
                          ? _blue
                          : _orange,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        _financeHeading('GASTOS DEL MES'),
        const SizedBox(height: 8),
        ...(periodEntries.where((entry) => entry.isExpense).isEmpty
            ? [
              _emptyCard(
                'Sin gastos registrados',
                'Los gastos generales y el mantenimiento de cancha aparecerán aquí.',
              ),
            ]
            : periodEntries
                .where((entry) => entry.isExpense)
                .map(_financeEntryCard)),
        const SizedBox(height: 12),
        _financeHeading('MOVIMIENTOS DEL MES'),
        const SizedBox(height: 8),
        ...(periodEntries.isEmpty
            ? [
              _emptyCard(
                'Sin movimientos registrados',
                'Registra cuotas, aportes y gastos para ver el balance mensual.',
              ),
            ]
            : periodEntries.map(_financeEntryCard)),
      ],
    );
  }

  Widget _financeHeading(String title) => Text(
    title,
    style: const TextStyle(
      color: _muted,
      fontWeight: FontWeight.w800,
      letterSpacing: .5,
      fontSize: 11,
    ),
  );

  Widget _financeEntryCard(FinanceEntry entry) {
    final isExpense = entry.isExpense;
    final title = switch (entry.kind) {
      'dues' => 'Cuota · ${entry.memberName ?? 'Miembro'}',
      'pledge' => 'Aporte · ${entry.memberName ?? 'Aporte comprometido'}',
      'visits' => 'VISITAS',
      'expense' =>
        entry.category == 'maintenance'
            ? 'Mantenimiento de cancha'
            : 'Gasto de la liga',
      _ =>
        entry.category == 'maintenance'
            ? 'Mantenimiento de cancha'
            : 'Gasto de la liga',
    };
    final subtitleParts = <String>[
      '${entry.date.day.toString().padLeft(2, '0')}/${entry.date.month.toString().padLeft(2, '0')}/${entry.date.year}',
      if (entry.paymentMethod == 'cash') 'Efectivo',
      if (entry.paymentMethod == 'deposit') 'Depósito',
      if (entry.description.isNotEmpty) entry.description,
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: (isExpense ? _orange : _blue).withValues(alpha: .15),
          child: Icon(
            isExpense ? Icons.north_east : Icons.south_west,
            color: isExpense ? _orange : _blue,
          ),
        ),
        title: Text(title),
        subtitle: Text(
          subtitleParts.join(' · '),
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        trailing: Text(
          '${isExpense ? '-' : '+'}${formatPesos(entry.amount)}',
          style: TextStyle(
            color: isExpense ? _orange : _blue,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Future<void> _deleteGame(Game game) async {
    if (!_canWrite) return;
    final overlayContext = _navigatorKey.currentContext;
    if (overlayContext == null) return;
    final confirmed = await showDialog<bool>(
      context: overlayContext,
      builder:
          (context) => AlertDialog(
            title: const Text('Eliminar partido y estadísticas'),
            content: Text(
              'Se eliminará ${game.home} ${game.homeScore} - ${game.awayScore} ${game.away} '
              'y se recalcularán las estadísticas de todos sus jugadores. Esta acción no se puede deshacer.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(backgroundColor: _orange),
                child: const Text('Eliminar partido'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await _backend.deleteGame(_selectedLeagueId!, game.id);
      if (!mounted) return;
      setState(() => games.removeWhere((item) => item.id == game.id));
      await _save();
    } catch (error) {
      _reportCloudError(error);
    }
  }

  Widget _gameCard(Game game) {
    final winner =
        game.homeScore == game.awayScore
            ? 'EMPATE'
            : game.homeScore > game.awayScore
            ? game.home
            : game.away;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  game.home,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (_canWrite)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _deleteGame(game),
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: const Text('Eliminar partido'),
                    style: TextButton.styleFrom(foregroundColor: _orange),
                  ),
                ),
              Text(
                '${game.homeScore}  -  ${game.awayScore}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Expanded(
                child: Text(
                  game.away,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${game.startedAt.day.toString().padLeft(2, '0')}/${game.startedAt.month.toString().padLeft(2, '0')}/${game.startedAt.year} · ${game.mode == 'points' ? 'A ${game.target} puntos' : 'Con tiempo'}',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ),
              Text(
                winner == 'EMPATE' ? winner : 'GANÓ $winner',
                style: TextStyle(
                  color: winner == 'EMPATE' ? _muted : _orange,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text(
              'Ver desglose del partido',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            children: [
              const Divider(height: 12),
              _gameRosterSection(game, game.home, game.homePlayers),
              const SizedBox(height: 10),
              _gameRosterSection(game, game.away, game.awayPlayers),
            ],
          ),
        ],
      ),
    );
  }

  Widget _gameRosterSection(
    Game game,
    String teamName,
    List<String> playerIds,
  ) {
    PlayerLine? lineFor(String playerId) {
      for (final line in game.lines) {
        if (line.playerId == playerId) return line;
      }
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          teamName,
          style: const TextStyle(
            color: _orange,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: .5,
          ),
        ),
        if (playerIds.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'No hay jugadores guardados para este equipo.',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
          )
        else
          ...playerIds.map((playerId) {
            final line = lineFor(playerId);
            final hasStats =
                line != null &&
                line.points +
                        line.rebounds +
                        line.assists +
                        line.threes +
                        line.steals +
                        line.turnovers +
                        line.blocks +
                        line.personalFouls >
                    0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _player(playerId)?.name ?? playerId,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (hasStats)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: Text(
                        '${line.points} pts · ${line.rebounds} reb · ${line.assists} ast · ${line.threes} 3pt · ${line.steals} ROB · ${line.turnovers} TO · ${line.blocks} BLK · ${line.personalFouls} FP',
                        style: const TextStyle(fontSize: 10, color: _muted),
                      ),
                    ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _sectionTitle(String title, String action, VoidCallback onTap) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: .7,
            fontSize: 12,
            color: _muted,
          ),
        ),
      ),
      TextButton(onPressed: onTap, child: Text(action)),
    ],
  );

  Widget _emptyCard(String title, String detail) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sports_basketball_outlined,
              color: _orange,
              size: 34,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, height: 1.4),
            ),
          ],
        ),
      ),
    ),
  );

  Player? _player(String id) {
    for (final player in players) {
      if (player.id == id) return player;
    }
    return null;
  }
}

class _AddPlayerSheet extends StatefulWidget {
  const _AddPlayerSheet({this.initialName, this.editing = false});

  final String? initialName;
  final bool editing;

  @override
  State<_AddPlayerSheet> createState() => _AddPlayerSheetState();
}

class _AddPlayerSheetState extends State<_AddPlayerSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.editing ? 'Editar jugador' : 'Registrar jugador',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nombre del jugador',
                hintText: 'Ej. Juan Pérez',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      widget.editing ? 'Guardar cambios' : 'Guardar jugador',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: const Color(0xFF241308),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceEntrySheet extends StatefulWidget {
  const _FinanceEntrySheet({
    required this.kind,
    required this.players,
    required this.monthlyDues,
    required this.period,
    required this.financeEntries,
    required this.contributionName,
    required this.contributionReceived,
  });

  final String kind;
  final List<Player> players;
  final int monthlyDues;
  final String period;
  final List<FinanceEntry> financeEntries;
  final String contributionName;
  final int contributionReceived;

  @override
  State<_FinanceEntrySheet> createState() => _FinanceEntrySheetState();
}

class _FinanceEntrySheetState extends State<_FinanceEntrySheet> {
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _memberId;
  late String _period;
  String _expenseCategory = 'general';
  String _paymentMethod = 'cash';
  String? _error;

  @override
  void initState() {
    super.initState();
    _period = widget.period;
    _memberId = _firstMemberWithBalance(_period);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  int _receivedForMember(String memberId, String period) => widget
      .financeEntries
      .where(
        (entry) =>
            entry.kind == 'dues' &&
            entry.memberId == memberId &&
            entry.period == period,
      )
      .fold(0, (total, entry) => total + entry.amount);

  String? _firstMemberWithBalance(String period) {
    for (final player in widget.players) {
      if (_receivedForMember(player.id, period) < widget.monthlyDues) {
        return player.id;
      }
    }
    return null;
  }

  List<String> get _availablePeriods {
    final parts = _period.split('-');
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null || month < 1 || month > 12) {
      return [widget.period];
    }
    return financePeriodChoices(DateTime(year, month));
  }

  int? get _remaining {
    if (widget.kind == 'dues' && _memberId != null) {
      return (widget.monthlyDues - _receivedForMember(_memberId!, _period))
          .clamp(0, widget.monthlyDues);
    }
    if (widget.kind == 'pledge') {
      return (_contributionPledge - widget.contributionReceived).clamp(
        0,
        _contributionPledge,
      );
    }
    return null;
  }

  String get _title => switch (widget.kind) {
    'dues' => 'Registrar abono de cuota',
    'pledge' => 'Registrar aporte de ${widget.contributionName}',
    'visits' => 'Registrar aporte de VISITAS',
    _ => 'Registrar gasto de la liga',
  };

  void _save() {
    final amount = int.tryParse(_amountController.text.trim());
    if (amount == null ||
        amount < 0 ||
        (amount == 0 && widget.kind != 'visits')) {
      setState(
        () =>
            _error =
                widget.kind == 'visits'
                    ? 'Escribe un monto válido para VISITAS.'
                    : 'Escribe un monto mayor que cero.',
      );
      return;
    }
    if (widget.kind == 'dues' && _memberId == null) {
      setState(() => _error = 'Selecciona un miembro con saldo pendiente.');
      return;
    }
    final remaining = _remaining;
    if (remaining != null && amount > remaining) {
      setState(
        () =>
            _error =
                'El monto supera el saldo pendiente de ${formatPesos(remaining)}.',
      );
      return;
    }
    final description = _descriptionController.text.trim();
    if (widget.kind == 'expense' && description.isEmpty) {
      setState(
        () => _error = 'Indica el detalle o a quién se realizó el pago.',
      );
      return;
    }
    final member = widget.players.where((player) => player.id == _memberId);
    final memberName = member.isEmpty ? null : member.first.name;
    final entry = FinanceEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: widget.kind,
      period: widget.kind == 'dues' ? _period : widget.period,
      date: DateTime.now(),
      amount: amount,
      category:
          widget.kind == 'expense'
              ? _expenseCategory
              : widget.kind == 'dues'
              ? 'dues'
              : widget.kind == 'pledge'
              ? 'contribution'
              : 'visits',
      description: description,
      paymentMethod:
          widget.kind == 'dues' || widget.kind == 'visits'
              ? _paymentMethod
              : null,
      memberId:
          widget.kind == 'dues'
              ? _memberId
              : widget.kind == 'pledge'
              ? _leagueContributionId
              : null,
      memberName:
          widget.kind == 'dues'
              ? memberName
              : widget.kind == 'pledge'
              ? widget.contributionName
              : widget.kind == 'visits'
              ? 'VISITAS'
              : null,
    );
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              '${financePeriodLabel(widget.kind == 'dues' ? _period : widget.period)} · Fecha de registro: ${DateTime.now().day.toString().padLeft(2, '0')}/${DateTime.now().month.toString().padLeft(2, '0')}/${DateTime.now().year}',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            if (widget.kind == 'dues') ...[
              DropdownButtonFormField<String>(
                value: _memberId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Miembro',
                  border: OutlineInputBorder(),
                ),
                items:
                    widget.players
                        .map(
                          (player) => DropdownMenuItem(
                            value: player.id,
                            enabled:
                                _receivedForMember(player.id, _period) <
                                widget.monthlyDues,
                            child: Text(
                              '${player.name} · pendiente ${formatPesos((widget.monthlyDues - _receivedForMember(player.id, _period)).clamp(0, widget.monthlyDues))}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                onChanged:
                    (id) => setState(() {
                      _memberId = id;
                      _error = null;
                    }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _period,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Mes que se está pagando',
                  border: OutlineInputBorder(),
                ),
                items:
                    _availablePeriods
                        .map(
                          (period) => DropdownMenuItem(
                            value: period,
                            child: Text(financePeriodLabel(period)),
                          ),
                        )
                        .toList(),
                onChanged: (period) {
                  if (period == null) return;
                  setState(() {
                    _period = period;
                    _memberId = _firstMemberWithBalance(period);
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 12),
              Text(
                'Cuota de ${formatPesos(widget.monthlyDues)} para el mes seleccionado. Puedes registrar abonos parciales o adelantar pagos de meses futuros.',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _paymentMethod,
                decoration: const InputDecoration(
                  labelText: 'Método de pago',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Efectivo')),
                  DropdownMenuItem(value: 'deposit', child: Text('Depósito')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _paymentMethod = value);
                  }
                },
              ),
            ],
            if (widget.kind == 'pledge') ...[
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.volunteer_activism, color: _blue),
                title: Text('Aporte comprometido'),
                subtitle: Text(
                  'Aporte mensual aparte de las cuotas de miembros',
                ),
              ),
              Text(
                'Aporte de ${widget.contributionName} · compromiso mensual ${formatPesos(_contributionPledge)} · pendiente ${formatPesos(_remaining ?? 0)}',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.kind == 'visits') ...[
              const Text(
                'Aporte por jugar en la cancha sin pertenecer a la liga. No tiene monto mínimo ni máximo.',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Detalle (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _paymentMethod,
                decoration: const InputDecoration(
                  labelText: 'Método de pago',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Efectivo')),
                  DropdownMenuItem(value: 'deposit', child: Text('Depósito')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _paymentMethod = value);
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
            if (widget.kind == 'expense') ...[
              DropdownButtonFormField<String>(
                value: _expenseCategory,
                decoration: const InputDecoration(
                  labelText: 'Tipo de gasto',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'general',
                    child: Text('Gasto general de la liga'),
                  ),
                  DropdownMenuItem(
                    value: 'maintenance',
                    child: Text('Mantenimiento de cancha'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _expenseCategory = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText:
                      _expenseCategory == 'maintenance'
                          ? 'Dueño de cancha o detalle del mantenimiento'
                          : 'Detalle del gasto',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Monto (RD\$)',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.payments_outlined),
                helperText: switch (widget.kind) {
                  'visits' => 'Sin mínimo ni máximo',
                  _ =>
                    _remaining == null
                        ? null
                        : 'Máximo para completar este mes: ${formatPesos(_remaining!)}',
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF796F))),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Guardar movimiento'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: const Color(0xFF241308),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _NewGameSheet extends StatefulWidget {
  const _NewGameSheet({required this.players});
  final List<Player> players;

  @override
  State<_NewGameSheet> createState() => _NewGameSheetState();
}

class _NewGameSheetState extends State<_NewGameSheet> {
  final _homeController = TextEditingController(text: 'Equipo A');
  final _awayController = TextEditingController(text: 'Equipo B');
  String _mode = 'points';
  int _target = 21;
  int _minutes = 10;
  final Set<String> _homePlayers = {};
  final Set<String> _awayPlayers = {};

  @override
  void dispose() {
    _homeController.dispose();
    _awayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 18,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Preparar partido',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _teamName(_homeController, 'Equipo local')),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _teamName(_awayController, 'Equipo visitante'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                'FORMATO DEL PARTIDO',
                style: TextStyle(
                  color: _muted,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'points',
                    label: Text('A puntos'),
                    icon: Icon(Icons.flag),
                  ),
                  ButtonSegment(
                    value: 'time',
                    label: Text('Con tiempo'),
                    icon: Icon(Icons.timer),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged:
                    (value) => setState(() => _mode = value.first),
              ),
              const SizedBox(height: 10),
              if (_mode == 'points')
                Row(
                  children: [
                    const Expanded(child: Text('Gana quien llegue primero a:')),
                    IconButton(
                      onPressed:
                          _target <= 1 ? null : () => setState(() => _target--),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$_target',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      onPressed: () => setState(() => _target++),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    const Expanded(child: Text('Duración del partido:')),
                    IconButton(
                      onPressed:
                          _minutes <= 1
                              ? null
                              : () => setState(() => _minutes--),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$_minutes min',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      onPressed: () => setState(() => _minutes++),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              _rosterPicker(_homeController.text, _homePlayers, _blue),
              const SizedBox(height: 8),
              _rosterPicker(_awayController.text, _awayPlayers, _orange),
              const SizedBox(height: 8),
              Text(
                'Selecciona exactamente 5 por equipo: '
                '${_homePlayers.length}/5 y ${_awayPlayers.length}/5.',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _homeController.text.trim().isEmpty ||
                              _awayController.text.trim().isEmpty ||
                              _homePlayers.length != 5 ||
                              _awayPlayers.length != 5
                          ? null
                          : _begin,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Comenzar partido'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _orange,
                    foregroundColor: const Color(0xFF241308),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _teamName(TextEditingController controller, String label) => TextField(
    controller: controller,
    textCapitalization: TextCapitalization.words,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    onChanged: (_) => setState(() {}),
  );

  Widget _rosterPicker(String team, Set<String> selected, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'JUGADORES · $team',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: .6,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children:
                widget.players.map((player) {
                  final chosen = selected.contains(player.id);
                  final selectingHome = identical(selected, _homePlayers);
                  final otherTeam =
                      selectingHome
                          ? _awayPlayers.contains(player.id)
                          : _homePlayers.contains(player.id);
                  final teamIsFull = selected.length >= 5 && !chosen;
                  return FilterChip(
                    label: Text(player.name),
                    selected: chosen,
                    onSelected:
                        otherTeam || teamIsFull
                            ? null
                            : (value) => setState(() {
                              if (value) {
                                selected.add(player.id);
                              } else {
                                selected.remove(player.id);
                              }
                            }),
                    selectedColor: color.withValues(alpha: .22),
                    showCheckmark: false,
                  );
                }).toList(),
          ),
        ],
      ),
    );
  }

  void _begin() {
    if (_homePlayers.length != 5 || _awayPlayers.length != 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Asigna exactamente 5 jugadores a cada equipo.'),
        ),
      );
      return;
    }
    final duration = _minutes * 60;
    Navigator.pop(
      context,
      Game(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        home: _homeController.text.trim(),
        away: _awayController.text.trim(),
        homePlayers: _homePlayers.toList(),
        awayPlayers: _awayPlayers.toList(),
        mode: _mode,
        target: _target,
        durationSeconds: duration,
        remainingSeconds: duration,
        startedAt: DateTime.now(),
      ),
    );
  }
}

class _CompareView extends StatefulWidget {
  const _CompareView({
    required this.players,
    required this.totalsFor,
    required this.games,
    required this.playerName,
  });

  final List<Player> players;
  final PlayerTotals Function(String) totalsFor;
  final List<Game> games;
  final String Function(String) playerName;

  @override
  State<_CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<_CompareView> {
  String? _first;
  String? _second;
  String? _teammatePlayer;
  String _rankingStat = 'points';
  String _statisticsPeriod = 'always';
  DateTime _statisticsDate = DateTime.now();
  String _performancePeriod = 'month';
  String? _performanceGameId;
  int _section = 0;

  static const _rankingCategories = [
    'points',
    'rebounds',
    'assists',
    'threes',
    'steals',
    'turnovers',
    'blocks',
    'personalFouls',
    'wins',
    'losses',
    'games',
  ];

  @override
  void initState() {
    super.initState();
    _syncPlayers();
  }

  @override
  void didUpdateWidget(covariant _CompareView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPlayers();
  }

  void _syncPlayers() {
    final ids = widget.players.map((player) => player.id).toSet();
    final firstPlayerId =
        widget.players.isEmpty ? null : widget.players.first.id;
    if (!ids.contains(_first)) _first = firstPlayerId;
    if (!ids.contains(_second)) {
      _second = widget.players.length > 1 ? widget.players[1].id : null;
    }
    if (!ids.contains(_teammatePlayer)) {
      _teammatePlayer = firstPlayerId;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Row(
            children: [
              _sectionChip(0, 'Cara a cara', Icons.compare_arrows),
              _sectionChip(1, 'Por estadística', Icons.leaderboard),
              _sectionChip(2, 'Compañeros', Icons.groups),
              _sectionChip(3, 'Mejor jugador', Icons.emoji_events),
            ],
          ),
        ),
        Expanded(
          child: switch (_section) {
            1 => _rankingScreen(),
            2 => _teammateScreen(),
            3 => _bestPlayerScreen(),
            _ => _comparisonScreen(),
          },
        ),
      ],
    );
  }

  Widget _sectionChip(int section, String label, IconData icon) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      avatar: Icon(icon, size: 17),
      label: Text(label),
      selected: _section == section,
      onSelected: (_) => setState(() => _section = section),
      selectedColor: _orange.withValues(alpha: .2),
      side: BorderSide(color: Colors.white.withValues(alpha: .08)),
    ),
  );

  Widget _comparisonScreen() => ListView(
    padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
    children: [
      const Text(
        'Comparar jugadores',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      const Text(
        'Cara a cara y líderes de la liga',
        style: TextStyle(color: _muted),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _playerDropdown(
                    'Jugador 1',
                    _first,
                    (value) => setState(() => _first = value),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.compare_arrows, color: _orange),
                ),
                Expanded(
                  child: _playerDropdown(
                    'Jugador 2',
                    _second,
                    (value) => setState(() => _second = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_first != null && _second != null && _first != _second)
              _headToHead()
            else
              const Text(
                'Selecciona dos jugadores distintos.',
                style: TextStyle(color: _muted),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _rankingScreen() {
    final filteredGames = _gamesForPeriod(_statisticsPeriod, _statisticsDate);
    final ranked = [...widget.players]..sort((a, b) {
      final difference =
          _rankingValue(_totalsForGames(b.id, filteredGames), _rankingStat) -
          _rankingValue(_totalsForGames(a.id, filteredGames), _rankingStat);
      return difference != 0
          ? difference
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
      children: [
        const Text(
          'Estadísticas de la liga',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Consulta a todos los jugadores, del mayor al menor.',
          style: TextStyle(color: _muted),
        ),
        const SizedBox(height: 14),
        _periodSelector(
          value: _statisticsPeriod,
          options: const {
            'always': 'Siempre',
            'day': 'Día',
            'week': 'Semana',
            'month': 'Mes',
          },
          onChanged: (value) => setState(() => _statisticsPeriod = value),
        ),
        if (_statisticsPeriod != 'always') ...[
          const SizedBox(height: 8),
          _dateSelector(_statisticsPeriod, _statisticsDate, (date) {
            setState(() => _statisticsDate = date);
          }),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _rankingStat,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Categoría estadística',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.filter_list),
          ),
          items:
              _rankingCategories
                  .map(
                    (category) => DropdownMenuItem(
                      value: category,
                      child: Text(_rankingLabel(category)),
                    ),
                  )
                  .toList(),
          onChanged: (value) {
            if (value != null) setState(() => _rankingStat = value);
          },
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children:
                ranked.asMap().entries.map((entry) {
                  final total = _totalsForGames(entry.value.id, filteredGames);
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          entry.key == 0
                              ? _orange.withValues(alpha: .2)
                              : _background,
                      child: Text(
                        '${entry.key + 1}',
                        style: TextStyle(
                          color: entry.key == 0 ? _orange : _muted,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(entry.value.name),
                    subtitle: Text(
                      '${total.games} partidos · ${total.wins} ganados · ${total.losses} perdidos',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                    trailing: Text(
                      '${_rankingValue(total, _rankingStat)}',
                      style: const TextStyle(
                        color: _orange,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  );
                }).toList(),
          ),
        ),
        if (filteredGames.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Text(
              'No hay partidos finalizados en este período.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted),
            ),
          ),
      ],
    );
  }

  Widget _bestPlayerScreen() {
    final filteredGames = _performanceGames();
    final performances = <String, int>{
      for (final player in widget.players)
        player.id: _performanceFor(player.id, filteredGames),
    };
    final ranked = [...widget.players]..sort((first, second) {
      final score =
          (performances[second.id] ?? 0) - (performances[first.id] ?? 0);
      return score != 0
          ? score
          : first.name.toLowerCase().compareTo(second.name.toLowerCase());
    });
    final finishedGames = widget.games.where((game) => game.finished);
    final selectedGameId =
        finishedGames.any((game) => game.id == _performanceGameId)
            ? _performanceGameId
            : finishedGames.isEmpty
            ? null
            : finishedGames.first.id;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
      children: [
        const Text(
          'Mejor jugador',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Ordenado por índice de rendimiento: PTS + REB + AST + ROB + BLK − TO.',
          style: TextStyle(color: _muted),
        ),
        const SizedBox(height: 14),
        _periodSelector(
          value: _performancePeriod,
          options: const {
            'game': 'Partido',
            'day': 'Día',
            'week': 'Semana',
            'month': 'Mes',
            'always': 'Siempre',
          },
          onChanged:
              (value) => setState(() {
                _performancePeriod = value;
                if (value == 'game') {
                  _performanceGameId =
                      widget.games
                          .where((game) => game.finished)
                          .firstOrNull
                          ?.id;
                }
              }),
        ),
        if (_performancePeriod == 'game' && widget.games.any((g) => g.finished))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DropdownButtonFormField<String>(
              value: selectedGameId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Partido',
                border: OutlineInputBorder(),
              ),
              items:
                  widget.games
                      .where((game) => game.finished)
                      .map(
                        (game) => DropdownMenuItem(
                          value: game.id,
                          child: Text(
                            '${_formatDate(game.startedAt)} · ${game.home} ${game.homeScore} - ${game.awayScore} ${game.away}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _performanceGameId = value);
                }
              },
            ),
          ),
        if (_performancePeriod != 'always' && _performancePeriod != 'game') ...[
          const SizedBox(height: 8),
          _dateSelector(_performancePeriod, _statisticsDate, (date) {
            setState(() => _statisticsDate = date);
          }),
        ],
        const SizedBox(height: 12),
        if (filteredGames.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Text(
              'No hay partidos finalizados en este período.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children:
                  ranked.asMap().entries.map((entry) {
                    final totals = _totalsForGames(
                      entry.value.id,
                      filteredGames,
                    );
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            entry.key == 0
                                ? _orange.withValues(alpha: .2)
                                : _background,
                        child: Text(
                          '${entry.key + 1}',
                          style: TextStyle(
                            color: entry.key == 0 ? _orange : _muted,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(entry.value.name),
                      subtitle: Text(
                        '${totals.points} pts · ${totals.rebounds} reb · ${totals.assists} ast · ${totals.steals} rob · ${totals.blocks} blk · ${totals.turnovers} TO',
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                      trailing: Text(
                        '${performances[entry.value.id]}',
                        style: const TextStyle(
                          color: _orange,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _periodSelector({
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) => DropdownButtonFormField<String>(
    value: value,
    isExpanded: true,
    decoration: const InputDecoration(
      labelText: 'Período',
      border: OutlineInputBorder(),
      prefixIcon: Icon(Icons.filter_list),
    ),
    items:
        options.entries
            .map(
              (entry) =>
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            )
            .toList(),
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );

  Widget _dateSelector(
    String period,
    DateTime date,
    ValueChanged<DateTime> onSelected,
  ) => OutlinedButton.icon(
    onPressed: () async {
      final selected = await showDatePicker(
        context: context,
        initialDate: date,
        firstDate: DateTime(2000),
        lastDate: DateTime.now(),
      );
      if (selected != null) onSelected(selected);
    },
    icon: const Icon(Icons.calendar_today, size: 17),
    label: Text(
      period == 'month'
          ? '${date.month.toString().padLeft(2, '0')}/${date.year}'
          : _formatDate(date),
    ),
  );

  List<Game> _gamesForPeriod(String period, DateTime date) =>
      widget.games.where((game) {
        if (!game.finished) return false;
        if (period == 'always') return true;
        if (period == 'day') return _isSameDay(game.startedAt, date);
        if (period == 'month') {
          return game.startedAt.year == date.year &&
              game.startedAt.month == date.month;
        }
        final weekStart = DateTime(
          date.year,
          date.month,
          date.day - (date.weekday - DateTime.monday),
        );
        final nextWeek = weekStart.add(const Duration(days: 7));
        return !game.startedAt.isBefore(weekStart) &&
            game.startedAt.isBefore(nextWeek);
      }).toList();

  List<Game> _performanceGames() {
    if (_performancePeriod == 'game') {
      final finishedGames =
          widget.games.where((game) => game.finished).toList();
      final gameId =
          finishedGames.any((game) => game.id == _performanceGameId)
              ? _performanceGameId
              : finishedGames.isEmpty
              ? null
              : finishedGames.first.id;
      return finishedGames.where((game) => game.id == gameId).toList();
    }
    return _gamesForPeriod(_performancePeriod, _statisticsDate);
  }

  PlayerTotals _totalsForGames(String playerId, List<Game> games) {
    final totals = PlayerTotals();
    for (final game in games) {
      final home = game.homePlayers.contains(playerId);
      final away = game.awayPlayers.contains(playerId);
      if (!home && !away) continue;
      totals.games++;
      final eligibleForResult =
          game.resultPlayerIds == null ||
          game.resultPlayerIds!.contains(playerId);
      if (eligibleForResult && game.homeScore != game.awayScore) {
        final playerWon = game.homeScore > game.awayScore ? home : away;
        if (playerWon) {
          totals.wins++;
        } else {
          totals.losses++;
        }
      }
      for (final line in game.lines.where(
        (line) => line.playerId == playerId,
      )) {
        totals.points += line.points;
        totals.rebounds += line.rebounds;
        totals.assists += line.assists;
        totals.threes += line.threes;
        totals.steals += line.steals;
        totals.turnovers += line.turnovers;
        totals.blocks += line.blocks;
        totals.personalFouls += line.personalFouls;
      }
    }
    return totals;
  }

  int _performanceFor(String playerId, List<Game> games) {
    final totals = _totalsForGames(playerId, games);
    return totals.points +
        totals.rebounds +
        totals.assists +
        totals.steals +
        totals.blocks -
        totals.turnovers;
  }

  bool _isSameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';

  Widget _teammateScreen() {
    final selectedId =
        widget.players.any((player) => player.id == _teammatePlayer)
            ? _teammatePlayer
            : null;
    final records =
        selectedId == null
            ? <String, _TeammateRecord>{}
            : _teammateRecords(selectedId);
    final teammates =
        records.keys.toList()..sort((a, b) {
          final first = records[a]!;
          final second = records[b]!;
          final wins = second.wins.compareTo(first.wins);
          if (wins != 0) return wins;
          final losses = first.losses.compareTo(second.losses);
          if (losses != 0) return losses;
          return second.games.compareTo(first.games);
        });
    final worstTeammates =
        records.keys.toList()..sort((a, b) {
          final first = records[a]!;
          final second = records[b]!;
          final losses = second.losses.compareTo(first.losses);
          if (losses != 0) return losses;
          final wins = first.wins.compareTo(second.wins);
          if (wins != 0) return wins;
          return second.games.compareTo(first.games);
        });

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
      children: [
        const Text(
          'Resultados con compañeros',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Mira con quién gana más y con quién acumula más derrotas.',
          style: TextStyle(color: _muted),
        ),
        const SizedBox(height: 14),
        _playerDropdown(
          'Selecciona un jugador',
          selectedId,
          (value) => setState(() => _teammatePlayer = value),
        ),
        if (records.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 18),
            child: Text(
              'No hay partidos finalizados compartidos con otros jugadores.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted),
            ),
          )
        else ...[
          const SizedBox(height: 20),
          _teammateList(
            'MEJORES COMPAÑEROS',
            'Ordenados por más victorias',
            teammates,
            records,
            Icons.emoji_events,
            _blue,
          ),
          const SizedBox(height: 18),
          _teammateList(
            'MÁS DERROTAS JUNTOS',
            'Ordenados por más derrotas',
            worstTeammates,
            records,
            Icons.trending_down,
            _orange,
          ),
        ],
      ],
    );
  }

  Map<String, _TeammateRecord> _teammateRecords(String playerId) {
    final records = <String, _TeammateRecord>{};
    for (final game in widget.games.where((game) => game.finished)) {
      final isHome = game.homePlayers.contains(playerId);
      final isAway = game.awayPlayers.contains(playerId);
      if (!isHome && !isAway) continue;
      if (game.resultPlayerIds != null &&
          !game.resultPlayerIds!.contains(playerId)) {
        continue;
      }
      final teammates = isHome ? game.homePlayers : game.awayPlayers;
      final won =
          game.homeScore == game.awayScore
              ? null
              : isHome
              ? game.homeScore > game.awayScore
              : game.awayScore > game.homeScore;
      for (final teammateId in teammates.where((id) => id != playerId)) {
        if (game.resultPlayerIds != null &&
            !game.resultPlayerIds!.contains(teammateId)) {
          continue;
        }
        final record = records.putIfAbsent(teammateId, _TeammateRecord.new);
        record.games++;
        if (won == null) {
          record.draws++;
        } else if (won) {
          record.wins++;
        } else {
          record.losses++;
        }
      }
    }
    return records;
  }

  Widget _teammateList(
    String title,
    String subtitle,
    List<String> teammateIds,
    Map<String, _TeammateRecord> records,
    IconData icon,
    Color color,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: .6,
            ),
          ),
        ],
      ),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(color: _muted, fontSize: 11)),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children:
              teammateIds.asMap().entries.map((entry) {
                final record = records[entry.value]!;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: .14),
                    child: Text(
                      '${entry.key + 1}',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(widget.playerName(entry.value)),
                  subtitle: Text(
                    '${record.wins} G · ${record.losses} P · ${record.draws} E · ${record.games} PJ',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                );
              }).toList(),
        ),
      ),
    ],
  );

  int _rankingValue(PlayerTotals totals, String category) => switch (category) {
    'points' => totals.points,
    'rebounds' => totals.rebounds,
    'assists' => totals.assists,
    'threes' => totals.threes,
    'steals' => totals.steals,
    'turnovers' => totals.turnovers,
    'blocks' => totals.blocks,
    'personalFouls' => totals.personalFouls,
    'wins' => totals.wins,
    'losses' => totals.losses,
    'games' => totals.games,
    _ => 0,
  };

  String _rankingLabel(String category) => switch (category) {
    'points' => 'Puntos',
    'rebounds' => 'Rebotes',
    'assists' => 'Asistencias',
    'threes' => 'Triples',
    'steals' => 'Robos (ROB)',
    'turnovers' => 'Balones perdidos (TO)',
    'blocks' => 'Tapas (BLK)',
    'personalFouls' => 'Faltas personales',
    'wins' => 'Partidos ganados',
    'losses' => 'Partidos perdidos',
    'games' => 'Partidos jugados',
    _ => category,
  };

  Widget _playerDropdown(
    String label,
    String? value,
    ValueChanged<String?> changed,
  ) => DropdownButtonFormField<String>(
    value: widget.players.any((player) => player.id == value) ? value : null,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    items:
        widget.players
            .map(
              (player) => DropdownMenuItem(
                value: player.id,
                child: Text(player.name, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
    onChanged: changed,
  );

  Widget _headToHead() {
    final first = widget.totalsFor(_first!);
    final second = widget.totalsFor(_second!);
    var firstWins = 0;
    var secondWins = 0;
    var ties = 0;
    for (final game in widget.games.where((item) => item.finished)) {
      final firstHome = game.homePlayers.contains(_first);
      final firstAway = game.awayPlayers.contains(_first);
      final secondHome = game.homePlayers.contains(_second);
      final secondAway = game.awayPlayers.contains(_second);
      final met = firstHome && secondAway || firstAway && secondHome;
      if (!met) continue;
      if (game.resultPlayerIds != null &&
          (!game.resultPlayerIds!.contains(_first) ||
              !game.resultPlayerIds!.contains(_second))) {
        continue;
      }
      if (game.homeScore == game.awayScore) {
        ties++;
      } else {
        final firstWon =
            game.homeScore > game.awayScore ? firstHome : firstAway;
        if (firstWon) {
          firstWins++;
        } else {
          secondWins++;
        }
      }
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _versusRecord(
                widget.playerName(_first!),
                firstWins,
                _blue,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'VS',
                style: TextStyle(color: _muted, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: _versusRecord(
                widget.playerName(_second!),
                secondWins,
                _orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Cara a cara: ${widget.playerName(_first!)} $firstWins victorias · '
          '${widget.playerName(_second!)} $secondWins victorias'
          '${ties > 0 ? ' · $ties empates' : ''}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const Divider(height: 24),
        _compareStat('PJ', first.games, second.games),
        _compareStat('Victorias', first.wins, second.wins),
        _compareStat('Derrotas', first.losses, second.losses),
        _compareStat('Puntos', first.points, second.points),
        _compareStat('Rebotes', first.rebounds, second.rebounds),
        _compareStat('Asistencias', first.assists, second.assists),
        _compareStat('Triples', first.threes, second.threes),
        _compareStat('Robos (ROB)', first.steals, second.steals),
        _compareStat(
          'Balones perdidos (TO)',
          first.turnovers,
          second.turnovers,
        ),
        _compareStat('Tapas (BLK)', first.blocks, second.blocks),
        _compareStat(
          'Faltas personales',
          first.personalFouls,
          second.personalFouls,
        ),
      ],
    );
  }

  Widget _versusRecord(String name, int wins, Color color) => Column(
    children: [
      Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
      Text(
        '$wins',
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900),
      ),
      const Text(
        'victorias H2H',
        style: TextStyle(color: _muted, fontSize: 10),
      ),
    ],
  );

  Widget _compareStat(String label, int first, int second) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '$first',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: first > second ? _blue : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            '$second',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: second > first ? _orange : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
}

class _AuthPage extends StatefulWidget {
  const _AuthPage({required this.backend});

  final LeagueBackend backend;

  @override
  State<_AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<_AuthPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _invitationController = TextEditingController();
  bool _register = false;
  bool _showPassword = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _invitationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        await widget.backend.register(
          _usernameController.text,
          _passwordController.text,
          _invitationController.text,
        );
      } else {
        await widget.backend.signIn(
          _usernameController.text,
          _passwordController.text,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = firebaseAuthMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: .06)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.sports_basketball, color: _orange, size: 44),
                  const SizedBox(height: 8),
                  const Text(
                    'PIZARRAFE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _register
                        ? 'Crea una cuenta para consultar la liga.'
                        : 'Inicia sesión para ver las estadísticas.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted),
                  ),
                  const SizedBox(height: 22),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('Iniciar sesión'),
                      ),
                      ButtonSegment(value: true, label: Text('Crear cuenta')),
                    ],
                    selected: {_register},
                    onSelectionChanged:
                        _busy
                            ? null
                            : (selection) => setState(() {
                              _register = selection.first;
                              _error = null;
                            }),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _usernameController,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de usuario',
                      hintText: 'Ej. jugador23',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    enabled: !_busy,
                    obscureText: !_showPassword,
                    decoration: InputDecoration(
                      labelText: 'Contraseña',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed:
                            () =>
                                setState(() => _showPassword = !_showPassword),
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_register)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: TextField(
                        controller: _invitationController,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Código de invitación',
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  if (_register)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Necesitas un código de un solo uso enviado por el administrador de la liga.',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFFF796F)),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: const Color(0xFF241308),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child:
                        _busy
                            ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : Text(_register ? 'Crear cuenta' : 'Entrar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FirebaseSetupApp extends StatelessWidget {
  const _FirebaseSetupApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _orange,
        brightness: Brightness.dark,
        surface: _surface,
      ),
    ),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, color: _orange, size: 48),
                const SizedBox(height: 14),
                const Text(
                  'Falta vincular la app con Firebase',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  kIsWeb
                      ? 'Registra una aplicación web en Firebase Console y '
                          'compila pasando su apiKey, appId, messagingSenderId '
                          'y projectId mediante --dart-define. Habilita '
                          'Email/Password y agrega el dominio de esta web '
                          'a los dominios autorizados de Firebase Authentication.'
                      : 'En Firebase Console, descarga google-services.json '
                          'para la app Android y colócalo en android/app/. '
                          'Habilita Email/Password y publica firestore.rules '
                          'en Firestore.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, height: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFF796F),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
