/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:core';

import 'package:http/http.dart' as http;

import '../encryption.dart';
import '../famedlysdk.dart';
import 'database/database.dart' show Database;
import 'event.dart';
import 'room.dart';
import 'user.dart';
import 'utils/device_keys_list.dart';
import 'utils/event_update.dart';
import 'utils/logs.dart';
import 'utils/matrix_file.dart';
import 'utils/room_update.dart';
import 'utils/to_device_event.dart';

typedef RoomSorter = int Function(Room a, Room b);

enum LoginState { logged, loggedOut }

/// Represents a Matrix client to communicate with a
/// [Matrix](https://matrix.org) homeserver and is the entry point for this
/// SDK.
class Client extends MatrixApi {
  int _id;
  int get id => _id;

  Database database;

  bool enableE2eeRecovery;

  @deprecated
  MatrixApi get api => this;

  Encryption encryption;

  Set<KeyVerificationMethod> verificationMethods;

  Set<String> importantStateEvents;

  Set<String> roomPreviewLastEvents;

  int sendMessageTimeoutSeconds;

  /// Create a client
  /// [clientName] = unique identifier of this client
  /// [database]: The database instance to use
  /// [enableE2eeRecovery]: Enable additional logic to try to recover from bad e2ee sessions
  /// [verificationMethods]: A set of all the verification methods this client can handle. Includes:
  ///    KeyVerificationMethod.numbers: Compare numbers. Most basic, should be supported
  ///    KeyVerificationMethod.emoji: Compare emojis
  /// [importantStateEvents]: A set of all the important state events to load when the client connects.
  ///    To speed up performance only a set of state events is loaded on startup, those that are
  ///    needed to display a room list. All the remaining state events are automatically post-loaded
  ///    when opening the timeline of a room or manually by calling `room.postLoad()`.
  ///    This set will always include the following state events:
  ///     - m.room.name
  ///     - m.room.avatar
  ///     - m.room.message
  ///     - m.room.encrypted
  ///     - m.room.encryption
  ///     - m.room.canonical_alias
  ///     - m.room.tombstone
  ///     - *some* m.room.member events, where needed
  /// [roomPreviewLastEvents]: The event types that should be used to calculate the last event
  ///     in a room for the room list.
  Client(
    this.clientName, {
    this.database,
    this.enableE2eeRecovery = false,
    this.verificationMethods,
    http.Client httpClient,
    this.importantStateEvents,
    this.roomPreviewLastEvents,
    this.pinUnreadRooms = false,
    this.sendMessageTimeoutSeconds = 60,
    @deprecated bool debug,
  }) {
    verificationMethods ??= <KeyVerificationMethod>{};
    importantStateEvents ??= {};
    importantStateEvents.addAll([
      EventTypes.RoomName,
      EventTypes.RoomAvatar,
      EventTypes.Message,
      EventTypes.Encrypted,
      EventTypes.Encryption,
      EventTypes.RoomCanonicalAlias,
      EventTypes.RoomTombstone,
    ]);
    roomPreviewLastEvents ??= {};
    roomPreviewLastEvents.addAll([
      EventTypes.Message,
      EventTypes.Encrypted,
      EventTypes.Sticker,
    ]);
    this.httpClient = httpClient ?? http.Client();
  }

  /// The required name for this client.
  final String clientName;

  /// The Matrix ID of the current logged user.
  String get userID => _userID;
  String _userID;

  /// This points to the position in the synchronization history.
  String prevBatch;

  /// The device ID is an unique identifier for this device.
  String get deviceID => _deviceID;
  String _deviceID;

  /// The device name is a human readable identifier for this device.
  String get deviceName => _deviceName;
  String _deviceName;

  /// Returns the current login state.
  bool isLogged() => accessToken != null;

  /// A list of all rooms the user is participating or invited.
  List<Room> get rooms => _rooms;
  List<Room> _rooms = [];

  /// Whether this client supports end-to-end encryption using olm.
  bool get encryptionEnabled => encryption != null && encryption.enabled;

  /// Whether this client is able to encrypt and decrypt files.
  bool get fileEncryptionEnabled => encryptionEnabled && true;

  String get identityKey => encryption?.identityKey ?? '';
  String get fingerprintKey => encryption?.fingerprintKey ?? '';

  /// Wheather this session is unknown to others
  bool get isUnknownSession =>
      !userDeviceKeys.containsKey(userID) ||
      !userDeviceKeys[userID].deviceKeys.containsKey(deviceID) ||
      !userDeviceKeys[userID].deviceKeys[deviceID].signed;

  /// Warning! This endpoint is for testing only!
  set rooms(List<Room> newList) {
    Logs.warning('Warning! This endpoint is for testing only!');
    _rooms = newList;
  }

  /// Key/Value store of account data.
  Map<String, BasicEvent> accountData = {};

  /// Presences of users by a given matrix ID
  Map<String, Presence> presences = {};

  int _transactionCounter = 0;

  String generateUniqueTransactionId() {
    _transactionCounter++;
    return '${clientName}-${_transactionCounter}-${DateTime.now().millisecondsSinceEpoch}';
  }

  Room getRoomByAlias(String alias) {
    for (var i = 0; i < rooms.length; i++) {
      if (rooms[i].canonicalAlias == alias) return rooms[i];
    }
    return null;
  }

  Room getRoomById(String id) {
    for (var j = 0; j < rooms.length; j++) {
      if (rooms[j].id == id) return rooms[j];
    }
    return null;
  }

  Map<String, dynamic> get directChats =>
      accountData['m.direct'] != null ? accountData['m.direct'].content : {};

  /// Returns the (first) room ID from the store which is a private chat with the user [userId].
  /// Returns null if there is none.
  String getDirectChatFromUserId(String userId) {
    if (accountData['m.direct'] != null &&
        accountData['m.direct'].content[userId] is List<dynamic> &&
        accountData['m.direct'].content[userId].length > 0) {
      for (final roomId in accountData['m.direct'].content[userId]) {
        final room = getRoomById(roomId);
        if (room != null && room.membership == Membership.join) {
          return roomId;
        }
      }
    }
    for (var i = 0; i < rooms.length; i++) {
      if (rooms[i].membership == Membership.invite &&
          rooms[i].states[userID]?.senderId == userId &&
          rooms[i].states[userID].content['is_direct'] == true) {
        return rooms[i].id;
      }
    }
    return null;
  }

  /// Gets discovery information about the domain. The file may include additional keys.
  Future<WellKnownInformations> getWellKnownInformationsByUserId(
    String MatrixIdOrDomain,
  ) async {
    final response = await http
        .get('https://${MatrixIdOrDomain.domain}/.well-known/matrix/client');
    var wellKnown = WellKnownInformations.fromJson(json.decode(response.body));
    if (Uri.parse(wellKnown.mHomeserver.baseUrl).host !=
        MatrixIdOrDomain.domain) {
      final response = await http.get(
          'https://${Uri.parse(wellKnown.mHomeserver.baseUrl).host}/.well-known/matrix/client');
      if (response.statusCode == 200) {
        wellKnown = WellKnownInformations.fromJson(json.decode(response.body));
      }
    }
    return wellKnown;
  }

  Future<WellKnownInformations> getWellKnownInformationsByDomain(
      dynamic serverUrl) async {
    var homeserver = (serverUrl is Uri) ? serverUrl : Uri.parse(serverUrl);
    final response =
        await http.get('https://${homeserver.host}/.well-known/matrix/client');
    var wellKnown = WellKnownInformations.fromJson(json.decode(response.body));
    if (Uri.parse(wellKnown.mHomeserver.baseUrl).host != homeserver.host) {
      final response = await http.get(
          'https://${Uri.parse(wellKnown.mHomeserver.baseUrl).host}/.well-known/matrix/client');
      if (response.statusCode == 200) {
        wellKnown = WellKnownInformations.fromJson(json.decode(response.body));
      }
    }
    return wellKnown;
  }

  /// Checks the supported versions of the Matrix protocol and the supported
  /// login types. Returns false if the server is not compatible with the
  /// client.
  /// Throws FormatException, TimeoutException and MatrixException on error.
  Future<bool> checkServer(dynamic serverUrl) async {
    try {
      if (serverUrl is Uri) {
        homeserver = serverUrl;
      } else {
        // URLs allow to have whitespace surrounding them, see https://www.w3.org/TR/2011/WD-html5-20110525/urls.html
        // As we want to strip a trailing slash, though, we have to trim the url ourself
        // and thus can't let Uri.parse() deal with it.
        serverUrl = serverUrl.trim();
        // strip a trailing slash
        if (serverUrl.endsWith('/')) {
          serverUrl = serverUrl.substring(0, serverUrl.length - 1);
        }
        homeserver = Uri.parse(serverUrl);
      }
      final versions = await requestSupportedVersions();

      for (var i = 0; i < versions.versions.length; i++) {
        if (versions.versions[i] == 'r0.5.0' ||
            versions.versions[i] == 'r0.6.0') {
          break;
        } else if (i == versions.versions.length - 1) {
          return false;
        }
      }

      final loginTypes = await requestLoginTypes();
      if (loginTypes.flows.indexWhere((f) => f.type == 'm.login.password') ==
          -1) {
        return false;
      }

      return true;
    } catch (_) {
      homeserver = null;
      rethrow;
    }
  }

  /// Checks to see if a username is available, and valid, for the server.
  /// Returns the fully-qualified Matrix user ID (MXID) that has been registered.
  /// You have to call [checkServer] first to set a homeserver.
  @override
  Future<LoginResponse> register({
    String username,
    String password,
    String deviceId,
    String initialDeviceDisplayName,
    bool inhibitLogin,
    Map<String, dynamic> auth,
    String kind,
  }) async {
    final response = await super.register(
      username: username,
      password: password,
      auth: auth,
      deviceId: deviceId,
      initialDeviceDisplayName: initialDeviceDisplayName,
      inhibitLogin: inhibitLogin,
    );

    // Connect if there is an access token in the response.
    if (response.accessToken == null ||
        response.deviceId == null ||
        response.userId == null) {
      throw 'Registered but token, device ID or user ID is null.';
    }
    await connect(
        newToken: response.accessToken,
        newUserID: response.userId,
        newHomeserver: homeserver,
        newDeviceName: initialDeviceDisplayName ?? '',
        newDeviceID: response.deviceId);
    return response;
  }

  /// Handles the login and allows the client to call all APIs which require
  /// authentication. Returns false if the login was not successful. Throws
  /// MatrixException if login was not successful.
  /// You have to call [checkServer] first to set a homeserver.
  @override
  Future<LoginResponse> login({
    String type = 'm.login.password',
    String userIdentifierType = 'm.id.user',
    String user,
    String medium,
    String address,
    String password,
    String token,
    String deviceId,
    String initialDeviceDisplayName,
  }) async {
    final loginResp = await super.login(
      type: type,
      userIdentifierType: userIdentifierType,
      user: user,
      password: password,
      deviceId: deviceId,
      initialDeviceDisplayName: initialDeviceDisplayName,
      medium: medium,
      address: address,
      token: token,
    );

    // Connect if there is an access token in the response.
    if (loginResp.accessToken == null ||
        loginResp.deviceId == null ||
        loginResp.userId == null) {
      throw Exception('Registered but token, device ID or user ID is null.');
    }
    await connect(
      newToken: loginResp.accessToken,
      newUserID: loginResp.userId,
      newHomeserver: homeserver,
      newDeviceName: initialDeviceDisplayName ?? '',
      newDeviceID: loginResp.deviceId,
    );
    return loginResp;
  }

  /// Sends a logout command to the homeserver and clears all local data,
  /// including all persistent data from the store.
  @override
  Future<void> logout() async {
    try {
      await super.logout();
    } catch (e, s) {
      Logs.error(e, s);
      rethrow;
    } finally {
      await clear();
    }
  }

  /// Sends a logout command to the homeserver and clears all local data,
  /// including all persistent data from the store.
  @override
  Future<void> logoutAll() async {
    try {
      await super.logoutAll();
    } catch (e, s) {
      Logs.error(e, s);
      rethrow;
    } finally {
      await clear();
    }
  }

  /// Returns the user's own displayname and avatar url. In Matrix it is possible that
  /// one user can have different displaynames and avatar urls in different rooms. So
  /// this endpoint first checks if the profile is the same in all rooms. If not, the
  /// profile will be requested from the homserver.
  Future<Profile> get ownProfile async {
    if (rooms.isNotEmpty) {
      var profileSet = <Profile>{};
      for (var room in rooms) {
        final user = room.getUserByMXIDSync(userID);
        profileSet.add(Profile.fromJson(user.content));
      }
      if (profileSet.length == 1) return profileSet.first;
    }
    return getProfileFromUserId(userID);
  }

  final Map<String, Profile> _profileCache = {};

  /// Get the combined profile information for this user.
  /// If [getFromRooms] is true then the profile will first be searched from the
  /// room memberships. This is unstable if the given user makes use of different displaynames
  /// and avatars per room, which is common for some bots and bridges.
  /// If [cache] is true then
  /// the profile get cached for this session. Please note that then the profile may
  /// become outdated if the user changes the displayname or avatar in this session.
  Future<Profile> getProfileFromUserId(String userId,
      {bool cache = true, bool getFromRooms = true}) async {
    if (getFromRooms) {
      final room = rooms.firstWhere(
          (Room room) =>
              room
                  .getParticipants()
                  .indexWhere((User user) => user.id == userId) !=
              -1,
          orElse: () => null);
      if (room != null) {
        final user =
            room.getParticipants().firstWhere((User user) => user.id == userId);
        return Profile(user.displayName, user.avatarUrl);
      }
    }
    if (cache && _profileCache.containsKey(userId)) {
      return _profileCache[userId];
    }
    final profile = await requestProfile(userId);
    _profileCache[userId] = profile;
    return profile;
  }

  Future<List<Room>> get archive async {
    var archiveList = <Room>[];
    final syncResp = await sync(
      filter: '{"room":{"include_leave":true,"timeline":{"limit":10}}}',
      timeout: 0,
    );
    if (syncResp.rooms.leave is Map<String, dynamic>) {
      for (var entry in syncResp.rooms.leave.entries) {
        final id = entry.key;
        final room = entry.value;
        var leftRoom = Room(
            id: id,
            membership: Membership.leave,
            client: this,
            roomAccountData:
                room.accountData?.asMap()?.map((k, v) => MapEntry(v.type, v)) ??
                    <String, BasicRoomEvent>{},
            mHeroes: []);
        if (room.timeline?.events != null) {
          for (var event in room.timeline.events) {
            leftRoom.setState(Event.fromMatrixEvent(event, leftRoom));
          }
        }
        if (room.state != null) {
          for (var event in room.state) {
            leftRoom.setState(Event.fromMatrixEvent(event, leftRoom));
          }
        }
        archiveList.add(leftRoom);
      }
    }
    return archiveList;
  }

  /// Uploads a new user avatar for this user.
  Future<void> setAvatar(MatrixFile file) async {
    final uploadResp = await upload(file.bytes, file.name);
    await setAvatarUrl(userID, Uri.parse(uploadResp));
    return;
  }

  /// Returns the push rules for the logged in user.
  PushRuleSet get pushRules => accountData.containsKey('m.push_rules')
      ? PushRuleSet.fromJson(accountData['m.push_rules'].content)
      : null;

  static String syncFilters = '{"room":{"state":{"lazy_load_members":true}}}';
  static String messagesFilters = '{"lazy_load_members":true}';
  static const List<String> supportedDirectEncryptionAlgorithms = [
    'm.olm.v1.curve25519-aes-sha2'
  ];
  static const List<String> supportedGroupEncryptionAlgorithms = [
    'm.megolm.v1.aes-sha2'
  ];
  static const int defaultThumbnailSize = 256;

  /// The newEvent signal is the most important signal in this concept. Every time
  /// the app receives a new synchronization, this event is called for every signal
  /// to update the GUI. For example, for a new message, it is called:
  /// onRoomEvent( "m.room.message", "!chat_id:server.com", "timeline", {sender: "@bob:server.com", body: "Hello world"} )
  final StreamController<EventUpdate> onEvent = StreamController.broadcast();

  /// Outside of the events there are updates for the global chat states which
  /// are handled by this signal:
  final StreamController<RoomUpdate> onRoomUpdate =
      StreamController.broadcast();

  /// The onToDeviceEvent is called when there comes a new to device event. It is
  /// already decrypted if necessary.
  final StreamController<ToDeviceEvent> onToDeviceEvent =
      StreamController.broadcast();

  /// Called when the login state e.g. user gets logged out.
  final StreamController<LoginState> onLoginStateChanged =
      StreamController.broadcast();

  /// Synchronization erros are coming here.
  final StreamController<MatrixException> onError =
      StreamController.broadcast();

  /// Synchronization erros are coming here.
  final StreamController<SdkError> onSyncError = StreamController.broadcast();

  /// Synchronization erros are coming here.
  final StreamController<ToDeviceEventDecryptionError> onOlmError =
      StreamController.broadcast();

  /// This is called once, when the first sync has received.
  final StreamController<bool> onFirstSync = StreamController.broadcast();

  /// When a new sync response is coming in, this gives the complete payload.
  final StreamController<SyncUpdate> onSync = StreamController.broadcast();

  /// Callback will be called on presences.
  final StreamController<Presence> onPresence = StreamController.broadcast();

  /// Callback will be called on account data updates.
  final StreamController<BasicEvent> onAccountData =
      StreamController.broadcast();

  /// Will be called on call invites.
  final StreamController<Event> onCallInvite = StreamController.broadcast();

  /// Will be called on call hangups.
  final StreamController<Event> onCallHangup = StreamController.broadcast();

  /// Will be called on call candidates.
  final StreamController<Event> onCallCandidates = StreamController.broadcast();

  /// Will be called on call answers.
  final StreamController<Event> onCallAnswer = StreamController.broadcast();

  /// Will be called when another device is requesting session keys for a room.
  final StreamController<RoomKeyRequest> onRoomKeyRequest =
      StreamController.broadcast();

  /// Will be called when another device is requesting verification with this device.
  final StreamController<KeyVerification> onKeyVerificationRequest =
      StreamController.broadcast();

  /// How long should the app wait until it retrys the synchronisation after
  /// an error?
  int syncErrorTimeoutSec = 3;

  /// Sets the user credentials and starts the synchronisation.
  ///
  /// Before you can connect you need at least an [accessToken], a [homeserver],
  /// a [userID], a [deviceID], and a [deviceName].
  ///
  /// You get this informations
  /// by logging in to your Matrix account, using the [login API](https://matrix.org/docs/spec/client_server/r0.4.0.html#post-matrix-client-r0-login).
  ///
  /// To log in you can use [jsonRequest()] after you have set the [homeserver]
  /// to a valid url. For example:
  ///
  /// ```
  /// final resp = await matrix
  ///          .jsonRequest(type: RequestType.POST, action: "/client/r0/login", data: {
  ///        "type": "m.login.password",
  ///        "user": "test",
  ///        "password": "1234",
  ///        "initial_device_display_name": "Matrix Client"
  ///      });
  /// ```
  ///
  /// Returns:
  ///
  /// ```
  /// {
  ///  "user_id": "@cheeky_monkey:matrix.org",
  ///  "access_token": "abc123",
  ///  "device_id": "GHTYAJCE"
  /// }
  /// ```
  ///
  /// Sends [LoginState.logged] to [onLoginStateChanged].
  void connect({
    String newToken,
    Uri newHomeserver,
    String newUserID,
    String newDeviceName,
    String newDeviceID,
    String newPrevBatch,
    String newOlmAccount,
  }) async {
    String olmAccount;
    if (database != null) {
      final account = await database.getClient(clientName);
      if (account != null) {
        _id = account.clientId;
        homeserver = Uri.parse(account.homeserverUrl);
        accessToken = account.token;
        _userID = account.userId;
        _deviceID = account.deviceId;
        _deviceName = account.deviceName;
        prevBatch = account.prevBatch;
        olmAccount = account.olmAccount;
      }
    }
    accessToken = newToken ?? accessToken;
    homeserver = newHomeserver ?? homeserver;
    _userID = newUserID ?? _userID;
    _deviceID = newDeviceID ?? _deviceID;
    _deviceName = newDeviceName ?? _deviceName;
    prevBatch = newPrevBatch ?? prevBatch;
    olmAccount = newOlmAccount ?? olmAccount;

    if (accessToken == null || homeserver == null || _userID == null) {
      // we aren't logged in
      encryption?.dispose();
      encryption = null;
      onLoginStateChanged.add(LoginState.loggedOut);
      return;
    }

    encryption?.dispose();
    encryption =
        Encryption(client: this, enableE2eeRecovery: enableE2eeRecovery);
    await encryption.init(olmAccount);

    if (database != null) {
      if (id != null) {
        await database.updateClient(
          homeserver.toString(),
          accessToken,
          _userID,
          _deviceID,
          _deviceName,
          prevBatch,
          encryption?.pickledOlmAccount,
          id,
        );
      } else {
        _id = await database.insertClient(
          clientName,
          homeserver.toString(),
          accessToken,
          _userID,
          _deviceID,
          _deviceName,
          prevBatch,
          encryption?.pickledOlmAccount,
        );
      }
      _userDeviceKeys = await database.getUserDeviceKeys(this);
      _rooms = await database.getRoomList(this, onlyLeft: false);
      _sortRooms();
      accountData = await database.getAccountData(id);
      presences.clear();
    }

    onLoginStateChanged.add(LoginState.logged);
    Logs.success(
      'Successfully connected as ${userID.localpart} with ${homeserver.toString()}',
    );

    // Always do a _sync after login, even if backgroundSync is set to off
    return _sync();
  }

  /// Used for testing only
  void setUserId(String s) {
    _userID = s;
  }

  /// Resets all settings and stops the synchronisation.
  void clear() {
    database?.clear(id);
    _id = accessToken =
        homeserver = _userID = _deviceID = _deviceName = prevBatch = null;
    _rooms = [];
    encryption?.dispose();
    encryption = null;
    onLoginStateChanged.add(LoginState.loggedOut);
  }

  bool _backgroundSync = true;
  Future<void> _currentSync, _retryDelay = Future.value();
  bool get syncPending => _currentSync != null;

  /// Controls the background sync (automatically looping forever if turned on).
  set backgroundSync(bool enabled) {
    _backgroundSync = enabled;
    if (_backgroundSync) {
      _sync();
    }
  }

  /// Immediately start a sync and wait for completion.
  /// If there is an active sync already, wait for the active sync instead.
  Future<void> oneShotSync() {
    return _sync();
  }

  Future<void> _sync() {
    if (_currentSync == null) {
      _currentSync = _innerSync();
      _currentSync.whenComplete(() {
        _currentSync = null;
        if (_backgroundSync && isLogged() && !_disposed) {
          _sync();
        }
      });
    }
    return _currentSync;
  }

  Future<void> _innerSync() async {
    await _retryDelay;
    _retryDelay = Future.delayed(Duration(seconds: syncErrorTimeoutSec));
    if (!isLogged() || _disposed) return null;
    try {
      final syncResp = await sync(
        filter: syncFilters,
        since: prevBatch,
        timeout: prevBatch != null ? 30000 : null,
      );
      if (_disposed) return;
      if (database != null) {
        _currentTransaction = database.transaction(() async {
          await handleSync(syncResp);
          if (prevBatch != syncResp.nextBatch) {
            await database.storePrevBatch(syncResp.nextBatch, id);
          }
        });
        await _currentTransaction;
      } else {
        await handleSync(syncResp);
      }
      if (_disposed) return;
      if (prevBatch == null) {
        onFirstSync.add(true);
        prevBatch = syncResp.nextBatch;
        _sortRooms();
      }
      prevBatch = syncResp.nextBatch;
      await database?.deleteOldFiles(
          DateTime.now().subtract(Duration(days: 30)).millisecondsSinceEpoch);
      await _updateUserDeviceKeys();
      if (encryptionEnabled) {
        encryption.onSync();
      }
      _retryDelay = Future.value();
    } on MatrixException catch (e) {
      onError.add(e);
    } catch (e, s) {
      if (!isLogged() || _disposed) return;
      Logs.error('Error during processing events: ' + e.toString(), s);
      onSyncError.add(SdkError(
          exception: e is Exception ? e : Exception(e), stackTrace: s));
      if (e is MatrixException &&
          e.errcode == MatrixError.M_UNKNOWN_TOKEN.toString().split('.').last) {
        Logs.warning('The user has been logged out!');
        clear();
      }
    }
  }

  /// Use this method only for testing utilities!
  Future<void> handleSync(SyncUpdate sync, {bool sortAtTheEnd = false}) async {
    if (sync.toDevice != null) {
      await _handleToDeviceEvents(sync.toDevice);
    }
    if (sync.rooms != null) {
      if (sync.rooms.join != null) {
        await _handleRooms(sync.rooms.join, Membership.join,
            sortAtTheEnd: sortAtTheEnd);
      }
      if (sync.rooms.invite != null) {
        await _handleRooms(sync.rooms.invite, Membership.invite,
            sortAtTheEnd: sortAtTheEnd);
      }
      if (sync.rooms.leave != null) {
        await _handleRooms(sync.rooms.leave, Membership.leave,
            sortAtTheEnd: sortAtTheEnd);
      }
      _sortRooms();
    }
    if (sync.presence != null) {
      for (final newPresence in sync.presence) {
        presences[newPresence.senderId] = newPresence;
        onPresence.add(newPresence);
      }
    }
    if (sync.accountData != null) {
      for (final newAccountData in sync.accountData) {
        if (database != null) {
          await database.storeAccountData(
            id,
            newAccountData.type,
            jsonEncode(newAccountData.content),
          );
        }
        accountData[newAccountData.type] = newAccountData;
        if (onAccountData != null) onAccountData.add(newAccountData);
      }
    }
    if (sync.deviceLists != null) {
      await _handleDeviceListsEvents(sync.deviceLists);
    }
    if (sync.deviceOneTimeKeysCount != null && encryptionEnabled) {
      encryption.handleDeviceOneTimeKeysCount(sync.deviceOneTimeKeysCount);
    }
    onSync.add(sync);
  }

  Future<void> _handleDeviceListsEvents(DeviceListsUpdate deviceLists) async {
    if (deviceLists.changed is List) {
      for (final userId in deviceLists.changed) {
        if (_userDeviceKeys.containsKey(userId)) {
          _userDeviceKeys[userId].outdated = true;
          if (database != null) {
            await database.storeUserDeviceKeysInfo(id, userId, true);
          }
        }
      }
      for (final userId in deviceLists.left) {
        if (_userDeviceKeys.containsKey(userId)) {
          _userDeviceKeys.remove(userId);
        }
      }
    }
  }

  Future<void> _handleToDeviceEvents(List<BasicEventWithSender> events) async {
    for (var i = 0; i < events.length; i++) {
      var toDeviceEvent = ToDeviceEvent.fromJson(events[i].toJson());
      if (toDeviceEvent.type == EventTypes.Encrypted && encryptionEnabled) {
        try {
          toDeviceEvent = await encryption.decryptToDeviceEvent(toDeviceEvent);
        } catch (e, s) {
          Logs.error(
              '[LibOlm] Could not decrypt to device event from ${toDeviceEvent.sender} with content: ${toDeviceEvent.content}\n${e.toString()}',
              s);

          onOlmError.add(
            ToDeviceEventDecryptionError(
              exception: e is Exception ? e : Exception(e),
              stackTrace: s,
              toDeviceEvent: toDeviceEvent,
            ),
          );
          toDeviceEvent = ToDeviceEvent.fromJson(events[i].toJson());
        }
      }
      if (encryptionEnabled) {
        await encryption.handleToDeviceEvent(toDeviceEvent);
      }
      onToDeviceEvent.add(toDeviceEvent);
    }
  }

  Future<void> _handleRooms(
      Map<String, SyncRoomUpdate> rooms, Membership membership,
      {bool sortAtTheEnd = false}) async {
    for (final entry in rooms.entries) {
      final id = entry.key;
      final room = entry.value;

      var update = RoomUpdate.fromSyncRoomUpdate(room, id);
      if (database != null) {
        await database.storeRoomUpdate(this.id, update, getRoomById(id));
      }
      _updateRoomsByRoomUpdate(update);
      final roomObj = getRoomById(id);
      if (update.limitedTimeline && roomObj != null) {
        roomObj.resetSortOrder();
      }
      onRoomUpdate.add(update);

      var handledEvents = false;

      /// Handle now all room events and save them in the database
      if (room is JoinedRoomUpdate) {
        if (room.state?.isNotEmpty ?? false) {
          await _handleRoomEvents(
              id, room.state.map((i) => i.toJson()).toList(), 'state');
          handledEvents = true;
        }
        if (room.timeline?.events?.isNotEmpty ?? false) {
          await _handleRoomEvents(
              id,
              room.timeline.events.map((i) => i.toJson()).toList(),
              sortAtTheEnd ? 'history' : 'timeline',
              sortAtTheEnd: sortAtTheEnd);
          handledEvents = true;
        }
        if (room.ephemeral?.isNotEmpty ?? false) {
          await _handleEphemerals(
              id, room.ephemeral.map((i) => i.toJson()).toList());
        }
        if (room.accountData?.isNotEmpty ?? false) {
          await _handleRoomEvents(id,
              room.accountData.map((i) => i.toJson()).toList(), 'account_data');
        }
      }
      if (room is LeftRoomUpdate) {
        if (room.timeline?.events?.isNotEmpty ?? false) {
          await _handleRoomEvents(id,
              room.timeline.events.map((i) => i.toJson()).toList(), 'timeline');
          handledEvents = true;
        }
        if (room.accountData?.isNotEmpty ?? false) {
          await _handleRoomEvents(id,
              room.accountData.map((i) => i.toJson()).toList(), 'account_data');
        }
        if (room.state?.isNotEmpty ?? false) {
          await _handleRoomEvents(
              id, room.state.map((i) => i.toJson()).toList(), 'state');
          handledEvents = true;
        }
      }
      if (room is InvitedRoomUpdate &&
          (room.inviteState?.isNotEmpty ?? false)) {
        await _handleRoomEvents(id,
            room.inviteState.map((i) => i.toJson()).toList(), 'invite_state');
      }
      if (handledEvents && database != null && roomObj != null) {
        await roomObj.updateSortOrder();
      }
    }
  }

  Future<void> _handleEphemerals(String id, List<dynamic> events) async {
    for (num i = 0; i < events.length; i++) {
      await _handleEvent(events[i], id, 'ephemeral');

      // Receipt events are deltas between two states. We will create a
      // fake room account data event for this and store the difference
      // there.
      if (events[i]['type'] == 'm.receipt') {
        var room = getRoomById(id);
        room ??= Room(id: id);

        var receiptStateContent =
            room.roomAccountData['m.receipt']?.content ?? {};
        for (var eventEntry in events[i]['content'].entries) {
          final String eventID = eventEntry.key;
          if (events[i]['content'][eventID]['m.read'] != null) {
            final Map<String, dynamic> userTimestampMap =
                events[i]['content'][eventID]['m.read'];
            for (var userTimestampMapEntry in userTimestampMap.entries) {
              final mxid = userTimestampMapEntry.key;

              // Remove previous receipt event from this user
              if (receiptStateContent[eventID] is Map<String, dynamic> &&
                  receiptStateContent[eventID]['m.read']
                      is Map<String, dynamic> &&
                  receiptStateContent[eventID]['m.read'].containsKey(mxid)) {
                receiptStateContent[eventID]['m.read'].remove(mxid);
              }
              if (userTimestampMap[mxid] is Map<String, dynamic> &&
                  userTimestampMap[mxid].containsKey('ts')) {
                receiptStateContent[mxid] = {
                  'event_id': eventID,
                  'ts': userTimestampMap[mxid]['ts'],
                };
              }
            }
          }
        }
        events[i]['content'] = receiptStateContent;
        await _handleEvent(events[i], id, 'account_data');
      }
    }
  }

  Future<void> _handleRoomEvents(
      String chat_id, List<dynamic> events, String type,
      {bool sortAtTheEnd = false}) async {
    for (num i = 0; i < events.length; i++) {
      await _handleEvent(events[i], chat_id, type, sortAtTheEnd: sortAtTheEnd);
    }
  }

  Future<void> _handleEvent(
      Map<String, dynamic> event, String roomID, String type,
      {bool sortAtTheEnd = false}) async {
    if (event['type'] is String && event['content'] is Map<String, dynamic>) {
      // The client must ignore any new m.room.encryption event to prevent
      // man-in-the-middle attacks!
      final room = getRoomById(roomID);
      if (room == null ||
          (event['type'] == EventTypes.Encryption &&
              room.encrypted &&
              event['content']['algorithm'] !=
                  room.getState(EventTypes.Encryption)?.content['algorithm'])) {
        return;
      }

      // ephemeral events aren't persisted and don't need a sort order - they are
      // expected to be processed as soon as they come in
      final sortOrder = type != 'ephemeral'
          ? (sortAtTheEnd ? room.oldSortOrder : room.newSortOrder)
          : 0.0;
      var update = EventUpdate(
        eventType: event['type'],
        roomID: roomID,
        type: type,
        content: event,
        sortOrder: sortOrder,
      );
      if (event['type'] == EventTypes.Encrypted && encryptionEnabled) {
        update = await update.decrypt(room);
      }
      if (event['type'] == EventTypes.Message &&
          !room.isDirectChat &&
          database != null &&
          room.getState(EventTypes.RoomMember, event['sender']) == null) {
        // In order to correctly render room list previews we need to fetch the member from the database
        final user = await database.getUser(id, event['sender'], room);
        if (user != null) {
          room.setState(user);
        }
      }
      if (type != 'ephemeral' && database != null) {
        await database.storeEventUpdate(id, update);
      }
      _updateRoomsByEventUpdate(update);
      if (encryptionEnabled) {
        await encryption.handleEventUpdate(update);
      }
      onEvent.add(update);

      final rawUnencryptedEvent = update.content;

      if (prevBatch != null && type == 'timeline') {
        if (rawUnencryptedEvent['type'] == EventTypes.CallInvite) {
          onCallInvite
              .add(Event.fromJson(rawUnencryptedEvent, room, sortOrder));
        } else if (rawUnencryptedEvent['type'] == EventTypes.CallHangup) {
          onCallHangup
              .add(Event.fromJson(rawUnencryptedEvent, room, sortOrder));
        } else if (rawUnencryptedEvent['type'] == EventTypes.CallAnswer) {
          onCallAnswer
              .add(Event.fromJson(rawUnencryptedEvent, room, sortOrder));
        } else if (rawUnencryptedEvent['type'] == EventTypes.CallCandidates) {
          onCallCandidates
              .add(Event.fromJson(rawUnencryptedEvent, room, sortOrder));
        }
      }
    }
  }

  void _updateRoomsByRoomUpdate(RoomUpdate chatUpdate) {
    // Update the chat list item.
    // Search the room in the rooms
    num j = 0;
    for (j = 0; j < rooms.length; j++) {
      if (rooms[j].id == chatUpdate.id) break;
    }
    final found = (j < rooms.length && rooms[j].id == chatUpdate.id);
    final isLeftRoom = chatUpdate.membership == Membership.leave;

    // Does the chat already exist in the list rooms?
    if (!found && !isLeftRoom) {
      var position = chatUpdate.membership == Membership.invite ? 0 : j;
      // Add the new chat to the list
      var newRoom = Room(
        id: chatUpdate.id,
        membership: chatUpdate.membership,
        prev_batch: chatUpdate.prev_batch,
        highlightCount: chatUpdate.highlight_count,
        notificationCount: chatUpdate.notification_count,
        mHeroes: chatUpdate.summary?.mHeroes,
        mJoinedMemberCount: chatUpdate.summary?.mJoinedMemberCount,
        mInvitedMemberCount: chatUpdate.summary?.mInvitedMemberCount,
        roomAccountData: {},
        client: this,
      );
      rooms.insert(position, newRoom);
    }
    // If the membership is "leave" then remove the item and stop here
    else if (found && isLeftRoom) {
      rooms.removeAt(j);
    }
    // Update notification, highlight count and/or additional informations
    else if (found &&
        chatUpdate.membership != Membership.leave &&
        (rooms[j].membership != chatUpdate.membership ||
            rooms[j].notificationCount != chatUpdate.notification_count ||
            rooms[j].highlightCount != chatUpdate.highlight_count ||
            chatUpdate.summary != null)) {
      rooms[j].membership = chatUpdate.membership;
      rooms[j].notificationCount = chatUpdate.notification_count;
      rooms[j].highlightCount = chatUpdate.highlight_count;
      if (chatUpdate.prev_batch != null) {
        rooms[j].prev_batch = chatUpdate.prev_batch;
      }
      if (chatUpdate.summary != null) {
        if (chatUpdate.summary.mHeroes != null) {
          rooms[j].mHeroes = chatUpdate.summary.mHeroes;
        }
        if (chatUpdate.summary.mJoinedMemberCount != null) {
          rooms[j].mJoinedMemberCount = chatUpdate.summary.mJoinedMemberCount;
        }
        if (chatUpdate.summary.mInvitedMemberCount != null) {
          rooms[j].mInvitedMemberCount = chatUpdate.summary.mInvitedMemberCount;
        }
      }
      if (rooms[j].onUpdate != null) rooms[j].onUpdate.add(rooms[j].id);
    }
  }

  void _updateRoomsByEventUpdate(EventUpdate eventUpdate) {
    if (eventUpdate.type == 'history') return;

    final room = getRoomById(eventUpdate.roomID);
    if (room == null) return;

    switch (eventUpdate.type) {
      case 'timeline':
      case 'state':
      case 'invite_state':
        var stateEvent =
            Event.fromJson(eventUpdate.content, room, eventUpdate.sortOrder);
        var prevState = room.getState(stateEvent.type, stateEvent.stateKey);
        if (prevState != null && prevState.sortOrder > stateEvent.sortOrder) {
          Logs.warning('''
A new ${eventUpdate.type} event of the type ${stateEvent.type} has arrived with a previews
sort order ${stateEvent.sortOrder} than the current ${stateEvent.type} event with a
sort order of ${prevState.sortOrder}. This should never happen...''');
          return;
        }
        if (stateEvent.type == EventTypes.Redaction) {
          final String redacts = eventUpdate.content['redacts'];
          room.states.states.forEach(
            (String key, Map<String, Event> states) => states.forEach(
              (String key, Event state) {
                if (state.eventId == redacts) {
                  state.setRedactionEvent(stateEvent);
                }
              },
            ),
          );
        } else {
          room.setState(stateEvent);
        }
        break;
      case 'account_data':
        room.roomAccountData[eventUpdate.eventType] =
            BasicRoomEvent.fromJson(eventUpdate.content);
        break;
      case 'ephemeral':
        room.ephemerals[eventUpdate.eventType] =
            BasicRoomEvent.fromJson(eventUpdate.content);
        break;
    }
    room.onUpdate.add(room.id);
  }

  bool _sortLock = false;

  /// If [true] then unread rooms are pinned at the top of the room list.
  bool pinUnreadRooms;

  /// The compare function how the rooms should be sorted internally. By default
  /// rooms are sorted by timestamp of the last m.room.message event or the last
  /// event if there is no known message.
  RoomSorter get sortRoomsBy => (a, b) => (a.isFavourite != b.isFavourite)
      ? (a.isFavourite ? -1 : 1)
      : (pinUnreadRooms && a.notificationCount != b.notificationCount)
          ? b.notificationCount.compareTo(a.notificationCount)
          : b.timeCreated.millisecondsSinceEpoch
              .compareTo(a.timeCreated.millisecondsSinceEpoch);

  void _sortRooms() {
    if (prevBatch == null || _sortLock || rooms.length < 2) return;
    _sortLock = true;
    rooms?.sort(sortRoomsBy);
    _sortLock = false;
  }

  /// A map of known device keys per user.
  Map<String, DeviceKeysList> get userDeviceKeys => _userDeviceKeys;
  Map<String, DeviceKeysList> _userDeviceKeys = {};

  /// Gets user device keys by its curve25519 key. Returns null if it isn't found
  DeviceKeys getUserDeviceKeysByCurve25519Key(String senderKey) {
    for (final user in userDeviceKeys.values) {
      final device = user.deviceKeys.values
          .firstWhere((e) => e.curve25519Key == senderKey, orElse: () => null);
      if (device != null) {
        return device;
      }
    }
    return null;
  }

  Future<Set<String>> _getUserIdsInEncryptedRooms() async {
    var userIds = <String>{};
    for (var i = 0; i < rooms.length; i++) {
      if (rooms[i].encrypted) {
        try {
          var userList = await rooms[i].requestParticipants();
          for (var user in userList) {
            if ([Membership.join, Membership.invite]
                .contains(user.membership)) {
              userIds.add(user.id);
            }
          }
        } catch (e, s) {
          Logs.error('[E2EE] Failed to fetch participants: ' + e.toString(), s);
        }
      }
    }
    return userIds;
  }

  final Map<String, DateTime> _keyQueryFailures = {};
  Future<void> _updateUserDeviceKeys() async {
    try {
      if (!isLogged()) return;
      final dbActions = <Future<dynamic> Function()>[];
      var trackedUserIds = await _getUserIdsInEncryptedRooms();
      trackedUserIds.add(userID);

      // Remove all userIds we no longer need to track the devices of.
      _userDeviceKeys
          .removeWhere((String userId, v) => !trackedUserIds.contains(userId));

      // Check if there are outdated device key lists. Add it to the set.
      var outdatedLists = <String, dynamic>{};
      for (var userId in trackedUserIds) {
        if (!userDeviceKeys.containsKey(userId)) {
          _userDeviceKeys[userId] = DeviceKeysList(userId, this);
        }
        var deviceKeysList = userDeviceKeys[userId];
        if (deviceKeysList.outdated &&
            (!_keyQueryFailures.containsKey(userId.domain) ||
                DateTime.now()
                    .subtract(Duration(minutes: 5))
                    .isAfter(_keyQueryFailures[userId.domain]))) {
          outdatedLists[userId] = [];
        }
      }

      if (outdatedLists.isNotEmpty) {
        // Request the missing device key lists from the server.
        if (!isLogged()) return;
        final response = await requestDeviceKeys(outdatedLists, timeout: 10000);

        for (final rawDeviceKeyListEntry in response.deviceKeys.entries) {
          final userId = rawDeviceKeyListEntry.key;
          if (!userDeviceKeys.containsKey(userId)) {
            _userDeviceKeys[userId] = DeviceKeysList(userId, this);
          }
          final oldKeys =
              Map<String, DeviceKeys>.from(_userDeviceKeys[userId].deviceKeys);
          _userDeviceKeys[userId].deviceKeys = {};
          for (final rawDeviceKeyEntry in rawDeviceKeyListEntry.value.entries) {
            final deviceId = rawDeviceKeyEntry.key;

            // Set the new device key for this device
            final entry =
                DeviceKeys.fromMatrixDeviceKeys(rawDeviceKeyEntry.value, this);
            if (entry.isValid) {
              // is this a new key or the same one as an old one?
              // better store an update - the signatures might have changed!
              if (!oldKeys.containsKey(deviceId) ||
                  oldKeys[deviceId].ed25519Key == entry.ed25519Key) {
                if (oldKeys.containsKey(deviceId)) {
                  // be sure to save the verified status
                  entry.setDirectVerified(oldKeys[deviceId].directVerified);
                  entry.blocked = oldKeys[deviceId].blocked;
                  entry.validSignatures = oldKeys[deviceId].validSignatures;
                }
                _userDeviceKeys[userId].deviceKeys[deviceId] = entry;
                if (deviceId == deviceID &&
                    entry.ed25519Key == fingerprintKey) {
                  // Always trust the own device
                  entry.setDirectVerified(true);
                }
              } else {
                // This shouldn't ever happen. The same device ID has gotten
                // a new public key. So we ignore the update. TODO: ask krille
                // if we should instead use the new key with unknown verified / blocked status
                _userDeviceKeys[userId].deviceKeys[deviceId] =
                    oldKeys[deviceId];
              }
            }
            if (database != null) {
              dbActions.add(() => database.storeUserDeviceKey(
                    id,
                    userId,
                    deviceId,
                    json.encode(entry.toJson()),
                    entry.directVerified,
                    entry.blocked,
                  ));
            }
          }
          // delete old/unused entries
          if (database != null) {
            for (final oldDeviceKeyEntry in oldKeys.entries) {
              final deviceId = oldDeviceKeyEntry.key;
              if (!_userDeviceKeys[userId].deviceKeys.containsKey(deviceId)) {
                // we need to remove an old key
                dbActions.add(
                    () => database.removeUserDeviceKey(id, userId, deviceId));
              }
            }
          }
          _userDeviceKeys[userId].outdated = false;
          if (database != null) {
            dbActions
                .add(() => database.storeUserDeviceKeysInfo(id, userId, false));
          }
        }
        // next we parse and persist the cross signing keys
        final crossSigningTypes = {
          'master': response.masterKeys,
          'self_signing': response.selfSigningKeys,
          'user_signing': response.userSigningKeys,
        };
        for (final crossSigningKeysEntry in crossSigningTypes.entries) {
          final keyType = crossSigningKeysEntry.key;
          final keys = crossSigningKeysEntry.value;
          if (keys == null) {
            continue;
          }
          for (final crossSigningKeyListEntry in keys.entries) {
            final userId = crossSigningKeyListEntry.key;
            if (!userDeviceKeys.containsKey(userId)) {
              _userDeviceKeys[userId] = DeviceKeysList(userId, this);
            }
            final oldKeys = Map<String, CrossSigningKey>.from(
                _userDeviceKeys[userId].crossSigningKeys);
            _userDeviceKeys[userId].crossSigningKeys = {};
            // add the types we aren't handling atm back
            for (final oldEntry in oldKeys.entries) {
              if (!oldEntry.value.usage.contains(keyType)) {
                _userDeviceKeys[userId].crossSigningKeys[oldEntry.key] =
                    oldEntry.value;
              }
            }
            final entry = CrossSigningKey.fromMatrixCrossSigningKey(
                crossSigningKeyListEntry.value, this);
            if (entry.isValid) {
              final publicKey = entry.publicKey;
              if (!oldKeys.containsKey(publicKey) ||
                  oldKeys[publicKey].ed25519Key == entry.ed25519Key) {
                if (oldKeys.containsKey(publicKey)) {
                  // be sure to save the verification status
                  entry.setDirectVerified(oldKeys[publicKey].directVerified);
                  entry.blocked = oldKeys[publicKey].blocked;
                  entry.validSignatures = oldKeys[publicKey].validSignatures;
                }
                _userDeviceKeys[userId].crossSigningKeys[publicKey] = entry;
              } else {
                // This shouldn't ever happen. The same device ID has gotten
                // a new public key. So we ignore the update. TODO: ask krille
                // if we should instead use the new key with unknown verified / blocked status
                _userDeviceKeys[userId].crossSigningKeys[publicKey] =
                    oldKeys[publicKey];
              }
              if (database != null) {
                dbActions.add(() => database.storeUserCrossSigningKey(
                      id,
                      userId,
                      publicKey,
                      json.encode(entry.toJson()),
                      entry.directVerified,
                      entry.blocked,
                    ));
              }
            }
            _userDeviceKeys[userId].outdated = false;
            if (database != null) {
              dbActions.add(
                  () => database.storeUserDeviceKeysInfo(id, userId, false));
            }
          }
        }

        // now process all the failures
        if (response.failures != null) {
          for (final failureDomain in response.failures.keys) {
            _keyQueryFailures[failureDomain] = DateTime.now();
          }
        }
      }

      if (dbActions.isNotEmpty) {
        await database?.transaction(() async {
          for (final f in dbActions) {
            await f();
          }
        });
      }
    } catch (e, s) {
      Logs.error(
          '[LibOlm] Unable to update user device keys: ' + e.toString(), s);
    }
  }

  /// Send an (unencrypted) to device [message] of a specific [eventType] to all
  /// devices of a set of [users].
  Future<void> sendToDevicesOfUserIds(
    Set<String> users,
    String eventType,
    Map<String, dynamic> message, {
    String messageId,
  }) async {
    // Send with send-to-device messaging
    var data = <String, Map<String, Map<String, dynamic>>>{};
    for (var user in users) {
      data[user] = {};
      data[user]['*'] = message;
    }
    await sendToDevice(
        eventType, messageId ?? generateUniqueTransactionId(), data);
    return;
  }

  /// Sends an encrypted [message] of this [type] to these [deviceKeys]. To send
  /// the request to all devices of the current user, pass an empty list to [deviceKeys].
  Future<void> sendToDeviceEncrypted(
    List<DeviceKeys> deviceKeys,
    String eventType,
    Map<String, dynamic> message, {
    String messageId,
    bool onlyVerified = false,
  }) async {
    if (!encryptionEnabled) return;
    // Don't send this message to blocked devices, and if specified onlyVerified
    // then only send it to verified devices
    if (deviceKeys.isNotEmpty) {
      deviceKeys.removeWhere((DeviceKeys deviceKeys) =>
          deviceKeys.blocked ||
          deviceKeys.deviceId == deviceID ||
          (onlyVerified && !deviceKeys.verified));
      if (deviceKeys.isEmpty) return;
    }

    // Send with send-to-device messaging
    var data = <String, Map<String, Map<String, dynamic>>>{};
    data =
        await encryption.encryptToDeviceMessage(deviceKeys, eventType, message);
    eventType = EventTypes.Encrypted;
    await sendToDevice(
        eventType, messageId ?? generateUniqueTransactionId(), data);
  }

  /// Whether all push notifications are muted using the [.m.rule.master]
  /// rule of the push rules: https://matrix.org/docs/spec/client_server/r0.6.0#m-rule-master
  bool get allPushNotificationsMuted {
    if (!accountData.containsKey('m.push_rules') ||
        !(accountData['m.push_rules'].content['global'] is Map)) {
      return false;
    }
    final Map<String, dynamic> globalPushRules =
        accountData['m.push_rules'].content['global'];
    if (globalPushRules == null) return false;

    if (globalPushRules['override'] is List) {
      for (var i = 0; i < globalPushRules['override'].length; i++) {
        if (globalPushRules['override'][i]['rule_id'] == '.m.rule.master') {
          return globalPushRules['override'][i]['enabled'];
        }
      }
    }
    return false;
  }

  Future<void> setMuteAllPushNotifications(bool muted) async {
    await enablePushRule(
      'global',
      PushRuleKind.override,
      '.m.rule.master',
      muted,
    );
    return;
  }

  /// Changes the password. You should either set oldPasswort or another authentication flow.
  @override
  Future<void> changePassword(String newPassword,
      {String oldPassword, Map<String, dynamic> auth}) async {
    try {
      if (oldPassword != null) {
        auth = {
          'type': 'm.login.password',
          'user': userID,
          'password': oldPassword,
        };
      }
      await super.changePassword(newPassword, auth: auth);
    } on MatrixException catch (matrixException) {
      if (!matrixException.requireAdditionalAuthentication) {
        rethrow;
      }
      if (matrixException.authenticationFlows.length != 1 ||
          !matrixException.authenticationFlows.first.stages
              .contains('m.login.password')) {
        rethrow;
      }
      if (oldPassword == null) {
        rethrow;
      }
      return changePassword(
        newPassword,
        auth: {
          'type': 'm.login.password',
          'user': userID,
          'identifier': {'type': 'm.id.user', 'user': userID},
          'password': oldPassword,
          'session': matrixException.session,
        },
      );
    } catch (_) {
      rethrow;
    }
  }

  /// Clear all local cached messages and perform a new clean sync.
  Future<void> clearLocalCachedMessages() async {
    prevBatch = null;
    rooms.forEach((r) => r.prev_batch = null);
    await database?.clearCache(id);
  }

  /// A list of mxids of users who are ignored.
  List<String> get ignoredUsers => (accountData
              .containsKey('m.ignored_user_list') &&
          accountData['m.ignored_user_list'].content['ignored_users'] is Map)
      ? List<String>.from(
          accountData['m.ignored_user_list'].content['ignored_users'].keys)
      : [];

  /// Ignore another user. This will clear the local cached messages to
  /// hide all previous messages from this user.
  Future<void> ignoreUser(String userId) async {
    if (!userId.isValidMatrixId) {
      throw Exception('$userId is not a valid mxid!');
    }
    await setAccountData(userID, 'm.ignored_user_list', {
      'ignored_users': Map.fromEntries(
          (ignoredUsers..add(userId)).map((key) => MapEntry(key, {}))),
    });
    await clearLocalCachedMessages();
    return;
  }

  /// Unignore a user. This will clear the local cached messages and request
  /// them again from the server to avoid gaps in the timeline.
  Future<void> unignoreUser(String userId) async {
    if (!userId.isValidMatrixId) {
      throw Exception('$userId is not a valid mxid!');
    }
    if (!ignoredUsers.contains(userId)) {
      throw Exception('$userId is not in the ignore list!');
    }
    await setAccountData(userID, 'm.ignored_user_list', {
      'ignored_users': Map.fromEntries(
          (ignoredUsers..remove(userId)).map((key) => MapEntry(key, {}))),
    });
    await clearLocalCachedMessages();
    return;
  }

  bool _disposed = false;
  Future _currentTransaction = Future.sync(() => {});

  /// Stops the synchronization and closes the database. After this
  /// you can safely make this Client instance null.
  Future<void> dispose({bool closeDatabase = false}) async {
    _disposed = true;
    try {
      await _currentTransaction;
    } catch (_) {
      // No-OP
    }
    encryption?.dispose();
    encryption = null;
    try {
      if (closeDatabase) await database?.close();
    } catch (error, stacktrace) {
      Logs.warning('Failed to close database: ' + error.toString(), stacktrace);
    }
    database = null;
    return;
  }
}

class SdkError {
  Exception exception;
  StackTrace stackTrace;
  SdkError({this.exception, this.stackTrace});
}
