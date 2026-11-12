import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LeagueIdentity {
  const LeagueIdentity(this.uid);

  final String uid;
}

abstract interface class LeagueBackend {
  Stream<LeagueIdentity?> get authChanges;
  LeagueIdentity? get currentUser;

  Future<void> signIn(String username, String password);
  Future<void> register(
    String username,
    String password,
    String invitationCode,
  );
  Future<void> signOut();
  Stream<Map<String, dynamic>?> watchProfile(String uid);
  Stream<Map<String, dynamic>?> watchLeague(String leagueId);
  Stream<List<Map<String, dynamic>>> watchAvailableLeagues(
    String uid,
    bool isOwner,
  );
  Stream<List<Map<String, dynamic>>> watchLeagueMembers(String leagueId);
  Future<void> ensureLegacyLeague(String uid);
  Future<void> migrateLegacyUsers();
  Future<String> createLeague(String name);
  Future<void> updateMonthlyDues(String leagueId, int amount);
  Future<String> createInvitation(String leagueId, String role);
  Future<void> redeemInvitation(String code);
  Stream<List<Map<String, dynamic>>> watchPlayers(String leagueId);
  Stream<List<Map<String, dynamic>>> watchGames(String leagueId);
  Stream<Map<String, dynamic>?> watchActiveGame(String leagueId);
  Stream<List<Map<String, dynamic>>> watchFinanceEntries(String leagueId);
  Future<void> migrateLegacyActiveResult(String leagueId);
  Future<void> finishGame(
    String leagueId,
    Map<String, dynamic> game,
    String activeGameId,
  );
  Future<void> clearActiveGame(String leagueId, String activeGameId);
  Future<void> changeRole(String leagueId, String uid, String role);
  Future<void> deletePlayer(String leagueId, String id);
  Future<void> deleteGame(String leagueId, String id);
  Future<void> addFinanceEntry(String leagueId, Map<String, dynamic> entry);
  Future<void> syncLeague({
    required String leagueId,
    required List<Map<String, dynamic>> players,
    required List<Map<String, dynamic>> games,
    required Map<String, dynamic>? activeGame,
  });
}

class FirebaseLeagueBackend implements LeagueBackend {
  FirebaseLeagueBackend({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final Map<String, Map<String, dynamic>> _playerCache = {};
  final Map<String, Map<String, dynamic>> _gameCache = {};
  Map<String, dynamic>? _activeGameCache;
  bool _playersReady = false;
  bool _gamesReady = false;
  bool _activeGameReady = false;
  final Random _random = Random.secure();
  String? _cacheLeagueId;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _leagues =>
      _firestore.collection('leagues');

  DocumentReference<Map<String, dynamic>> _league(String leagueId) =>
      _leagues.doc(leagueId);

  CollectionReference<Map<String, dynamic>> _memberships(String uid) =>
      _users.doc(uid).collection('memberships');

  CollectionReference<Map<String, dynamic>> _members(String leagueId) =>
      _league(leagueId).collection('members');

  CollectionReference<Map<String, dynamic>> _players(String leagueId) =>
      _league(leagueId).collection('players');

  CollectionReference<Map<String, dynamic>> _games(String leagueId) =>
      _league(leagueId).collection('games');

  CollectionReference<Map<String, dynamic>> _financeEntries(String leagueId) =>
      _league(leagueId).collection('financeEntries');

  DocumentReference<Map<String, dynamic>> _activeGame(String leagueId) =>
      _league(leagueId).collection('state').doc('active');

  DocumentReference<Map<String, dynamic>> _gameSession(String leagueId) =>
      _league(leagueId).collection('state').doc('gameSession');

  CollectionReference<Map<String, dynamic>> get _invitations =>
      _firestore.collection('invitations');

  @override
  LeagueIdentity? get currentUser {
    final user = _auth.currentUser;
    return user == null ? null : LeagueIdentity(user.uid);
  }

  @override
  Stream<LeagueIdentity?> get authChanges => _auth.authStateChanges().map(
    (user) => user == null ? null : LeagueIdentity(user.uid),
  );

  @override
  Future<void> signIn(String username, String password) async {
    final normalized = _normalizeUsername(username);
    await _auth.signInWithEmailAndPassword(
      email: _emailFor(normalized),
      password: password,
    );
  }

  @override
  Future<void> register(
    String username,
    String password,
    String invitationCode,
  ) async {
    final normalized = _normalizeUsername(username);
    final code = _normalizeInvitationCode(invitationCode);
    final credential = await _auth.createUserWithEmailAndPassword(
      email: _emailFor(normalized),
      password: password,
    );
    final user = credential.user;
    if (user == null) {
      throw StateError('Firebase no devolvió el usuario recién creado.');
    }

    try {
      await _redeemInvitation(
        code,
        uid: user.uid,
        username: normalized,
        createProfile: true,
      );
    } catch (error) {
      await user.delete();
      rethrow;
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Stream<Map<String, dynamic>?> watchProfile(String uid) =>
      _users.doc(uid).snapshots().map((snapshot) => snapshot.data());

  @override
  Stream<Map<String, dynamic>?> watchLeague(String leagueId) =>
      _league(leagueId)
          .snapshots(includeMetadataChanges: true)
          .where((snapshot) => !snapshot.metadata.isFromCache)
          .map((snapshot) => snapshot.data());

  @override
  Stream<List<Map<String, dynamic>>> watchAvailableLeagues(
    String uid,
    bool isOwner,
  ) {
    if (isOwner) {
      return _leagues
          .orderBy('name')
          .snapshots()
          .map(
            (snapshot) =>
                snapshot.docs
                    .map(
                      (doc) => {...doc.data(), 'id': doc.id, 'role': 'owner'},
                    )
                    .toList(),
          );
    }
    return _memberships(uid).snapshots().asyncMap((snapshot) async {
      final leagues = await Future.wait(
        snapshot.docs.map((membership) async {
          final leagueId = membership.id;
          final league = await _league(leagueId).get();
          final data = league.data();
          if (!league.exists || data == null) return null;
          return {
            ...data,
            'id': leagueId,
            'role': membership.data()['role'] as String? ?? 'viewer',
          };
        }),
      );
      return leagues.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    });
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLeagueMembers(String leagueId) =>
      _members(leagueId)
          .orderBy('username')
          .snapshots()
          .map(
            (snapshot) =>
                snapshot.docs
                    .map((doc) => {...doc.data(), 'uid': doc.id})
                    .toList(),
          );

  @override
  Future<void> ensureLegacyLeague(String uid) async {
    final profile = await _users.doc(uid).get();
    if (profile.data()?['role'] != 'owner') {
      throw StateError('Solo rreyes puede preparar Liga La Fe.');
    }
    final league = _league('main');
    final snapshot = await league.get();
    if (!snapshot.exists) {
      await league.set({
        'name': 'Liga La Fe',
        'monthlyDues': 300,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      final data = snapshot.data()!;
      final updates = <String, dynamic>{};
      if (data['name'] != 'Liga La Fe') updates['name'] = 'Liga La Fe';
      if (data['monthlyDues'] is! int) updates['monthlyDues'] = 300;
      if (updates.isNotEmpty) {
        await league.set(updates, SetOptions(merge: true));
      }
    }
  }

  @override
  Future<void> migrateLegacyUsers() async {
    final users = await _users.get();
    final writes = <({String uid, Map<String, dynamic> membership})>[];
    for (final user in users.docs) {
      final data = user.data();
      if (data['role'] == 'owner') continue;
      writes.add((
        uid: user.id,
        membership: {
          'uid': user.id,
          'username': data['username'] as String? ?? user.id,
          'leagueId': 'main',
          'role': data['role'] == 'admin' ? 'admin' : 'viewer',
          'createdAt': FieldValue.serverTimestamp(),
        },
      ));
    }
    for (var start = 0; start < writes.length; start += 200) {
      final batch = _firestore.batch();
      for (final entry in writes.skip(start).take(200)) {
        batch.set(
          _members('main').doc(entry.uid),
          entry.membership,
          SetOptions(merge: true),
        );
        batch.set(
          _memberships(entry.uid).doc('main'),
          entry.membership,
          SetOptions(merge: true),
        );
      }
      await batch.commit();
    }
  }

  @override
  Future<String> createLeague(String name) async {
    final cleanName = name.trim();
    if (cleanName.length < 2 || cleanName.length > 60) {
      throw const FormatException(
        'El nombre debe tener entre 2 y 60 caracteres.',
      );
    }
    final user = _auth.currentUser;
    if (user == null) throw StateError('Inicia sesión para crear una liga.');
    final league = _leagues.doc();
    await league.set({
      'name': cleanName,
      'monthlyDues': 300,
      'createdBy': user.uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return league.id;
  }

  @override
  Future<void> updateMonthlyDues(String leagueId, int amount) async {
    if (amount < 1 || amount > 100000000) {
      throw RangeError.range(amount, 1, 100000000, 'amount');
    }
    await _league(leagueId).update({'monthlyDues': amount});
  }

  @override
  Future<String> createInvitation(String leagueId, String role) async {
    if (role != 'admin' && role != 'viewer') {
      throw ArgumentError.value(role, 'role', 'Rol inválido.');
    }
    final user = _auth.currentUser;
    if (user == null) throw StateError('Inicia sesión para invitar.');
    final alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final code =
        List.generate(
          20,
          (_) => alphabet[_random.nextInt(alphabet.length)],
        ).join();
    await _invitations.doc(code).set({
      'leagueId': leagueId,
      'role': role,
      'createdBy': user.uid,
      'used': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return code;
  }

  @override
  Future<void> redeemInvitation(String code) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('Inicia sesión para usar una invitación.');
    }
    await _redeemInvitation(
      _normalizeInvitationCode(code),
      uid: user.uid,
      username: user.email?.split('@').first ?? user.uid,
      createProfile: false,
    );
  }

  Future<void> _redeemInvitation(
    String code, {
    required String uid,
    required String username,
    required bool createProfile,
  }) async {
    final invitation = _invitations.doc(code);
    final profile = _users.doc(uid);
    await _firestore.runTransaction((transaction) async {
      final invitationSnapshot = await transaction.get(invitation);
      if (!invitationSnapshot.exists) {
        throw const FormatException('El código de invitación no es válido.');
      }
      final invitationData = invitationSnapshot.data()!;
      if (invitationData['used'] != false) {
        throw const FormatException(
          'Este código de invitación ya fue utilizado.',
        );
      }
      final leagueId = invitationData['leagueId'] as String;
      final role = invitationData['role'] as String;
      final userMembership = _memberships(uid).doc(leagueId);
      final leagueMember = _members(leagueId).doc(uid);
      final userMembershipSnapshot = await transaction.get(userMembership);
      if (userMembershipSnapshot.exists) {
        throw const FormatException('Ya perteneces a esta liga.');
      }
      if (createProfile) {
        transaction.set(profile, {
          'uid': uid,
          'username': username,
          'role': 'viewer',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        final profileSnapshot = await transaction.get(profile);
        if (!profileSnapshot.exists) {
          throw StateError('No se encontró el perfil de usuario.');
        }
      }
      final membership = {
        'uid': uid,
        'username': username,
        'leagueId': leagueId,
        'role': role,
        'invitationId': code,
        'createdAt': FieldValue.serverTimestamp(),
      };
      transaction.set(userMembership, membership);
      transaction.set(leagueMember, membership);
      transaction.update(invitation, {
        'used': true,
        'usedBy': uid,
        'usedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  Stream<List<Map<String, dynamic>>> watchPlayers(String leagueId) =>
      _players(leagueId)
          .snapshots(includeMetadataChanges: true)
          .where((snapshot) => !snapshot.metadata.isFromCache)
          .map((snapshot) {
            _prepareCache(leagueId);
            _playerCache
              ..clear()
              ..addEntries(
                snapshot.docs.map(
                  (doc) => MapEntry(doc.id, {...doc.data(), 'id': doc.id}),
                ),
              );
            _playersReady = true;
            return _playerCache.values.toList();
          });

  @override
  Stream<List<Map<String, dynamic>>> watchGames(String leagueId) =>
      _games(leagueId)
          .snapshots(includeMetadataChanges: true)
          .where((snapshot) => !snapshot.metadata.isFromCache)
          .map((snapshot) {
            _prepareCache(leagueId);
            _gameCache
              ..clear()
              ..addEntries(
                snapshot.docs.map(
                  (doc) => MapEntry(doc.id, {...doc.data(), 'id': doc.id}),
                ),
              );
            _gamesReady = true;
            return _gameCache.values.toList();
          });

  @override
  Stream<Map<String, dynamic>?> watchActiveGame(String leagueId) =>
      _activeGame(leagueId)
          .snapshots(includeMetadataChanges: true)
          .where((snapshot) => !snapshot.metadata.isFromCache)
          .map((snapshot) {
            _prepareCache(leagueId);
            if (snapshot.exists) {
              final data = snapshot.data()!;
              _activeGameCache = {
                ...data,
                'id': data['activeGameId'] as String? ?? snapshot.id,
              };
            } else {
              _activeGameCache = null;
            }
            _activeGameReady = true;
            return _activeGameCache;
          });

  @override
  Stream<List<Map<String, dynamic>>> watchFinanceEntries(String leagueId) =>
      _financeEntries(leagueId)
          .snapshots(includeMetadataChanges: true)
          .where((snapshot) => !snapshot.metadata.isFromCache)
          .map(
            (snapshot) =>
                snapshot.docs
                    .map((doc) => {...doc.data(), 'id': doc.id})
                    .toList(),
          );

  @override
  Future<void> changeRole(String leagueId, String uid, String role) async {
    if (role != 'admin' && role != 'viewer') {
      throw ArgumentError.value(role, 'role', 'Rol inválido.');
    }
    final batch = _firestore.batch();
    batch.update(_memberships(uid).doc(leagueId), {'role': role});
    batch.update(_members(leagueId).doc(uid), {'role': role});
    await batch.commit();
  }

  @override
  Future<void> deletePlayer(String leagueId, String id) async {
    await _players(leagueId).doc(id).delete();
    _playerCache.remove(id);
  }

  @override
  Future<void> deleteGame(String leagueId, String id) async {
    await _games(leagueId).doc(id).delete();
    _gameCache.remove(id);
  }

  @override
  Future<void> migrateLegacyActiveResult(String leagueId) async {
    final legacyRef = _games(leagueId).doc('active');
    final migratedRef = _games(leagueId).doc();
    final migrated = await _firestore.runTransaction((transaction) async {
      final legacy = await transaction.get(legacyRef);
      if (!legacy.exists) return false;
      transaction.set(migratedRef, legacy.data()!);
      transaction.delete(legacyRef);
      return true;
    });
    if (!migrated) return;
    final legacy = _gameCache.remove('active');
    if (legacy != null) {
      final data = Map<String, dynamic>.from(legacy)..remove('id');
      _gameCache[migratedRef.id] = {...data, 'id': migratedRef.id};
    }
  }

  @override
  Future<void> finishGame(
    String leagueId,
    Map<String, dynamic> game,
    String activeGameId,
  ) async {
    if (_cacheLeagueId != leagueId ||
        !_gamesReady ||
        !_activeGameReady ||
        !_playersReady) {
      throw StateError('La liga aún no terminó de sincronizarse.');
    }
    final id = game['id'] as String;
    if (id == 'active') {
      throw StateError(
        'El identificador reservado de la partida activa no se puede usar en el historial.',
      );
    }
    final data = Map<String, dynamic>.from(game)..remove('id');
    final gameRef = _games(leagueId).doc(id);
    final activeRef = _activeGame(leagueId);
    final sessionRef = _gameSession(leagueId);
    final batch = _firestore.batch();
    batch.set(gameRef, data);
    batch.delete(activeRef);
    batch.set(sessionRef, {
      'gameId': activeGameId,
      'status': 'finished',
      'finishedGameId': id,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    try {
      await batch.commit().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      final saved = await _confirmFinishedGame(
        gameRef,
        data,
        sessionRef,
        activeGameId,
      );
      if (!saved) {
        throw TimeoutException(
          'Firestore no confirmó el resultado después de 30 segundos.',
        );
      }
    }
    _gameCache[id] = {...data, 'id': id};
    _activeGameCache = null;
  }

  @override
  Future<void> clearActiveGame(String leagueId, String activeGameId) async {
    if (_cacheLeagueId != leagueId || !_activeGameReady) {
      throw StateError('La liga aún no terminó de sincronizarse.');
    }
    final batch = _firestore.batch();
    batch.delete(_activeGame(leagueId));
    batch.set(_gameSession(leagueId), {
      'gameId': activeGameId,
      'status': 'discarded',
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    _activeGameCache = null;
  }

  @override
  Future<void> addFinanceEntry(
    String leagueId,
    Map<String, dynamic> entry,
  ) async {
    final id = entry['id'] as String;
    final data = Map<String, dynamic>.from(entry)..remove('id');
    await _financeEntries(leagueId).doc(id).set(data);
  }

  @override
  Future<void> syncLeague({
    required String leagueId,
    required List<Map<String, dynamic>> players,
    required List<Map<String, dynamic>> games,
    required Map<String, dynamic>? activeGame,
  }) async {
    if (_cacheLeagueId != leagueId ||
        !_playersReady ||
        !_gamesReady ||
        !_activeGameReady) {
      throw StateError('La liga aún no terminó de sincronizarse.');
    }
    if (activeGame?['id'] == 'active') {
      throw StateError(
        'Se descartó una actualización antigua con el ID reservado de la partida activa.',
      );
    }
    await _syncGamesAndActive(leagueId, games, activeGame);
    await _syncCollection(_players(leagueId), _playerCache, players);
  }

  Future<void> _syncGamesAndActive(
    String leagueId,
    List<Map<String, dynamic>> games,
    Map<String, dynamic>? activeGame,
  ) async {
    final desiredGames = <String, Map<String, dynamic>>{
      for (final entry in games)
        entry['id'] as String: Map<String, dynamic>.from(entry)..remove('id'),
    };
    if (desiredGames.length < _gameCache.length) {
      throw StateError(
        'Sincronización cancelada para proteger los datos existentes: '
        'la lista local tiene menos registros que los cargados del servidor.',
      );
    }
    final changedGames = <String, Map<String, dynamic>>{
      for (final entry in desiredGames.entries)
        if (_canonical(_gameCache[entry.key]) != _canonical(entry.value))
          entry.key: entry.value,
    };
    Map<String, dynamic>? activeData;
    if (activeGame != null) {
      activeData = Map<String, dynamic>.from(activeGame);
      activeData.remove('id');
      activeData['activeGameId'] = activeGame['id'];
    }
    Map<String, dynamic>? cachedActiveData;
    if (_activeGameCache != null) {
      cachedActiveData = Map<String, dynamic>.from(_activeGameCache!);
      cachedActiveData.remove('id');
    }
    final activeChanged =
        _canonical(cachedActiveData) != _canonical(activeData);

    if (changedGames.length <= 499) {
      if (changedGames.isNotEmpty) {
        final batch = _firestore.batch();
        for (final entry in changedGames.entries) {
          batch.set(_games(leagueId).doc(entry.key), entry.value);
        }
        await batch.commit();
      }
    } else {
      final operations = changedGames.entries.toList();
      for (var start = 0; start < operations.length; start += 450) {
        final batch = _firestore.batch();
        for (final operation in operations.skip(start).take(450)) {
          batch.set(_games(leagueId).doc(operation.key), operation.value);
        }
        await batch.commit();
      }
    }

    if (activeChanged && activeData != null) {
      final activeId = activeGame!['id'] as String;
      final activeSaved = await _writeActiveIfSessionMatches(
        leagueId,
        activeId,
        activeData,
      );
      _activeGameCache = activeSaved ? {...activeData, 'id': activeId} : null;
    } else if (activeChanged &&
        activeData == null &&
        _activeGameCache != null) {
      final activeId =
          _activeGameCache!['activeGameId'] as String? ??
          _activeGameCache!['id'] as String? ??
          'legacy-active';
      await clearActiveGame(leagueId, activeId);
    } else {
      _activeGameCache =
          activeData == null ? null : {...activeData, 'id': 'active'};
    }

    _gameCache.addAll({
      for (final entry in desiredGames.entries)
        entry.key: {...entry.value, 'id': entry.key},
    });
  }

  Future<bool> _writeActiveIfSessionMatches(
    String leagueId,
    String gameId,
    Map<String, dynamic> activeData,
  ) {
    final activeRef = _activeGame(leagueId);
    final sessionRef = _gameSession(leagueId);
    return _firestore
        .runTransaction((transaction) async {
          final sessionSnapshot = await transaction.get(sessionRef);
          final session = sessionSnapshot.data();
          if (session != null) {
            final currentId = session['gameId'];
            if (currentId == gameId && session['status'] != 'active') {
              return false;
            }
            if (session['status'] == 'active' && currentId != gameId) {
              return false;
            }
          }
          if (session == null ||
              session['gameId'] != gameId ||
              session['status'] != 'active') {
            transaction.set(sessionRef, {
              'gameId': gameId,
              'status': 'active',
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
          transaction.set(activeRef, activeData);
          return true;
        })
        .timeout(const Duration(seconds: 30));
  }

  Future<bool> _confirmFinishedGame(
    DocumentReference<Map<String, dynamic>> gameRef,
    Map<String, dynamic> expectedData,
    DocumentReference<Map<String, dynamic>> sessionRef,
    String activeGameId,
  ) async {
    try {
      final snapshots = await Future.wait([
        gameRef.get(const GetOptions(source: Source.server)),
        sessionRef.get(const GetOptions(source: Source.server)),
      ]).timeout(const Duration(seconds: 10));
      final game = snapshots[0];
      final session = snapshots[1];
      return game.exists &&
          _canonical(game.data()) == _canonical(expectedData) &&
          session.data()?['status'] == 'finished' &&
          session.data()?['gameId'] == activeGameId;
    } catch (error) {
      throw TimeoutException(
        'Firestore no confirmó el resultado; tampoco fue posible verificarlo '
        'directamente en el servidor (${firebaseAuthMessage(error)}).',
      );
    }
  }

  void _prepareCache(String leagueId) {
    if (_cacheLeagueId == leagueId) return;
    _cacheLeagueId = leagueId;
    _playerCache.clear();
    _gameCache.clear();
    _activeGameCache = null;
    _playersReady = false;
    _gamesReady = false;
    _activeGameReady = false;
  }

  Future<void> _syncCollection(
    CollectionReference<Map<String, dynamic>> collection,
    Map<String, Map<String, dynamic>> cache,
    List<Map<String, dynamic>> entries,
  ) async {
    final desired = <String, Map<String, dynamic>>{
      for (final entry in entries)
        entry['id'] as String: Map<String, dynamic>.from(entry)..remove('id'),
    };
    if (desired.length < cache.length) {
      throw StateError(
        'Sincronización cancelada para proteger los datos existentes: '
        'la lista local tiene menos registros que los cargados del servidor.',
      );
    }
    final changed = <String, Map<String, dynamic>>{
      for (final entry in desired.entries)
        if (_canonical(cache[entry.key]) != _canonical(entry.value))
          entry.key: entry.value,
    };
    final operations = changed.entries.toList();

    for (var start = 0; start < operations.length; start += 450) {
      final batch = _firestore.batch();
      for (final operation in operations.skip(start).take(450)) {
        batch.set(collection.doc(operation.key), operation.value);
      }
      await batch.commit();
    }

    cache.addAll({
      for (final entry in desired.entries)
        entry.key: {...entry.value, 'id': entry.key},
    });
  }

  String _normalizeUsername(String username) {
    final normalized = username.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9._-]{3,24}$').hasMatch(normalized)) {
      throw const FormatException(
        'El usuario debe tener de 3 a 24 caracteres: letras, números, punto, guion o guion bajo.',
      );
    }
    return normalized;
  }

  String _emailFor(String username) => '$username@pizarrafe.firebaseapp.com';

  String _normalizeInvitationCode(String code) {
    final normalized = code.trim().toUpperCase();
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{20}$').hasMatch(normalized)) {
      throw const FormatException('Escribe un código de invitación válido.');
    }
    return normalized;
  }

  String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '$key:${_canonical(value[key])}').join(',')}}';
    }
    if (value is Iterable) {
      return '[${value.map(_canonical).join(',')}]';
    }
    return jsonEncode(value);
  }
}

String firebaseAuthMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is TimeoutException) {
    return error.message ??
        'Firestore no confirmó el guardado en 30 segundos. '
            'Comprueba la conexión y pulsa “Reintentar guardado”.';
  }
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'email-already-in-use' => 'Ese nombre de usuario ya está registrado.',
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' => 'Usuario o contraseña incorrectos.',
      'weak-password' => 'La contraseña debe tener al menos 6 caracteres.',
      'network-request-failed' =>
        'No hay conexión. Revisa tu internet e inténtalo.',
      'too-many-requests' => 'Demasiados intentos. Espera un momento.',
      'operation-not-allowed' =>
        'Firebase aún no tiene habilitado el acceso con correo y contraseña.',
      _ => 'No se pudo completar el acceso (${error.code}).',
    };
  }
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' =>
        'Firestore rechazó el guardado por permisos. Revisa las reglas y que tu usuario sea administrador de esta liga.',
      'resource-exhausted' =>
        'Firestore agotó la cuota de operaciones del proyecto (Quota exceeded). No es un rechazo de reglas: revisa el uso/cuota de Firestore en Firebase Console y espera el reinicio o habilita facturación; después reintenta.',
      'unauthenticated' =>
        'La sesión de Firebase expiró. Cierra sesión, vuelve a entrar e intenta guardar.',
      'unavailable' || 'deadline-exceeded' =>
        'Firestore no está respondiendo. Revisa la conexión e intenta guardar de nuevo.',
      _ =>
        'Firestore rechazó la operación (${error.code}): ${error.message ?? 'sin más detalles'}.',
    };
  }
  return 'No se pudo conectar con Firebase: $error';
}
