// The coach-digest client: response parsing and every branch of the fetch
// (missing endpoint, expired token, server errors, offline). The IMAP polling
// and summarization live on the server, so nothing here needs a mailbox — an
// injected http client stands in for the whole backend.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xctraining/auth_service.dart';
import 'package:xctraining/coach_mail.dart';

/// A signed-in AuthService backed by mock prefs.
Future<AuthService> signedIn() async {
  SharedPreferences.setMockInitialValues({
    'auth_token': 'test-jwt',
    'auth_email': 'runner@school.edu',
    'auth_issued_at': DateTime.now().toIso8601String(),
  });
  // Empty client ID keeps load() away from the Google Sign-In plugin.
  final auth = AuthService(serverBase: 'http://test', googleServerClientId: '');
  await auth.load();
  return auth;
}

/// A JSON response with an explicit charset. Without it `http.Response`
/// encodes the body as latin1, which throws on any non-ASCII character the
/// digest might legitimately contain (an em-dash, a name with an accent).
http.Response jsonOk(String body, [int status = 200]) => http.Response(
  body,
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

String digestBody({
  String headline = 'Meet Saturday — bus leaves at 7am',
  List<String> bullets = const ['Track workout Tuesday', 'Easy 4 Wednesday'],
  List<String> actions = const ['Turn in the travel form'],
  String generatedAt = '2026-08-10T13:00:00Z',
  int sourceCount = 3,
  List<Map<String, dynamic>>? messages,
}) => jsonEncode({
  'digest': {
    'headline': headline,
    'bullets': bullets,
    'actions': actions,
    'generated_at': generatedAt,
    'source_count': sourceCount,
  },
  'messages':
      messages ??
      [
        {
          'id': '<a@school.edu>',
          'from': 'coach@school.edu',
          'from_name': 'Coach Kim',
          'subject': 'Saturday meet',
          'date': '2026-08-09T18:00:00Z',
          'body': 'Bus leaves at 7am sharp.',
        },
      ],
});

void main() {
  group('parseDigestResponse', () {
    test('reads the digest and its source emails', () {
      final result = parseDigestResponse(digestBody());
      expect(result.status, CoachMailStatus.ok);
      expect(result.digest!.headline, 'Meet Saturday — bus leaves at 7am');
      expect(result.digest!.bullets, hasLength(2));
      expect(result.digest!.actions, ['Turn in the travel form']);
      expect(result.digest!.sourceCount, 3);
      expect(result.messages, hasLength(1));
      expect(result.messages.first.displaySender, 'Coach Kim');
      expect(result.messages.first.subject, 'Saturday meet');
    });

    test('a null digest with no messages is empty, not an error', () {
      final result = parseDigestResponse(
        jsonEncode({'digest': null, 'messages': []}),
      );
      expect(result.status, CoachMailStatus.empty);
      expect(result.digest, isNull);
    });

    test('a digest with no content is treated as empty', () {
      // The server has run but found nothing worth saying — the card should
      // say "no coach email yet" rather than render a blank headline.
      final result = parseDigestResponse(
        jsonEncode({
          'digest': {'headline': '', 'bullets': [], 'actions': []},
          'messages': [],
        }),
      );
      expect(result.status, CoachMailStatus.empty);
      expect(result.digest, isNull);
    });

    test('drops blank bullets rather than rendering empty rows', () {
      final result = parseDigestResponse(
        jsonEncode({
          'digest': {
            'headline': 'H',
            'bullets': ['ok', '', '   '],
            'actions': null,
          },
          'messages': [],
        }),
      );
      expect(result.digest!.bullets, ['ok']);
      expect(result.digest!.actions, isEmpty);
    });

    test('tolerates missing optional fields', () {
      final result = parseDigestResponse(
        jsonEncode({
          'digest': {'headline': 'Just a headline'},
        }),
      );
      expect(result.status, CoachMailStatus.ok);
      expect(result.digest!.headline, 'Just a headline');
      expect(result.digest!.bullets, isEmpty);
      expect(result.digest!.sourceCount, 0);
      expect(result.messages, isEmpty);
    });

    test('parses dates into local time', () {
      final result = parseDigestResponse(digestBody());
      expect(result.digest!.generatedAt.isUtc, isFalse);
      expect(result.digest!.generatedAt.toUtc(), DateTime.utc(2026, 8, 10, 13));
    });
  });

  group('CoachMailService.fetch', () {
    test('returns the digest and caches it for the next launch', () async {
      final auth = await signedIn();
      final service = CoachMailService(
        auth: auth,
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/coach-digest');
          expect(request.headers['Authorization'], 'Bearer test-jwt');
          return jsonOk(digestBody());
        }),
      );

      final result = await service.fetch();
      expect(result.status, CoachMailStatus.ok);
      expect(result.digest!.headline, contains('Meet Saturday'));

      // A fresh service (cold launch) still has something to paint.
      final cached = await CoachMailService(auth: auth).loadCached();
      expect(cached.digest!.headline, contains('Meet Saturday'));
      expect(cached.messages, hasLength(1));
    });

    test('hides the card when the server has no such endpoint', () async {
      final auth = await signedIn();
      var calls = 0;
      final service = CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('Not Found', 404);
        }),
      );

      final result = await service.fetch();
      expect(result.status, CoachMailStatus.notConfigured);
      expect(service.isUnavailable, isTrue);

      // Later calls short-circuit instead of re-probing a server we know
      // doesn't implement this.
      await service.fetch();
      await service.refresh();
      expect(calls, 1);
    });

    test('501 is also treated as not deployed', () async {
      final service = CoachMailService(
        auth: await signedIn(),
        httpClient: MockClient((_) async => http.Response('nope', 501)),
      );
      expect((await service.fetch()).status, CoachMailStatus.notConfigured);
    });

    test('renders nothing when signed out', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = AuthService(
        serverBase: 'http://test',
        googleServerClientId: '',
      );
      await auth.load();
      var called = false;
      final service = CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async {
          called = true;
          return jsonOk(digestBody());
        }),
      );
      expect((await service.fetch()).status, CoachMailStatus.notConfigured);
      expect(called, isFalse);
    });

    test('401 drops the token so the sign-in card comes back', () async {
      final auth = await signedIn();
      final service = CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async => http.Response('nope', 401)),
      );
      final result = await service.fetch();
      expect(result.status, CoachMailStatus.error);
      expect(result.message, contains('Sign-in expired'));
      expect(auth.isSignedIn, isFalse);
    });

    test('a server error keeps the cached digest on screen', () async {
      final auth = await signedIn();
      await CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async => jsonOk(digestBody())),
      ).fetch();

      final result = await CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      ).fetch();

      expect(result.status, CoachMailStatus.error);
      expect(result.message, contains('500'));
      expect(result.digest!.headline, contains('Meet Saturday'));
      expect(result.messages, hasLength(1));
    });

    test('being offline reports a connection problem, not a crash', () async {
      final auth = await signedIn();
      final result = await CoachMailService(
        auth: auth,
        httpClient: MockClient(
          (_) async => throw http.ClientException('SocketException: no route'),
        ),
      ).fetch();
      expect(result.status, CoachMailStatus.error);
      expect(result.message, contains('Could not reach the server'));
    });

    test('a malformed body is surfaced, not swallowed', () async {
      final result = await CoachMailService(
        auth: await signedIn(),
        httpClient: MockClient((_) async => http.Response('<html>oops', 200)),
      ).fetch();
      expect(result.status, CoachMailStatus.error);
      expect(result.message, contains('Could not read the digest'));
    });
  });

  group('CoachMailService.refresh', () {
    test('POSTs to the refresh endpoint', () async {
      var path = '';
      var method = '';
      final service = CoachMailService(
        auth: await signedIn(),
        httpClient: MockClient((request) async {
          path = request.url.path;
          method = request.method;
          return jsonOk(digestBody());
        }),
      );
      final result = await service.refresh();
      expect(method, 'POST');
      expect(path, '/coach-digest/refresh');
      expect(result.status, CoachMailStatus.ok);
    });
  });

  group('cache', () {
    test('clearCache empties the local copy', () async {
      final auth = await signedIn();
      final service = CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async => jsonOk(digestBody())),
      );
      await service.fetch();
      expect((await service.loadCached()).digest, isNotNull);

      await service.clearCache();
      final cleared = await service.loadCached();
      expect(cleared.digest, isNull);
      expect(cleared.messages, isEmpty);
      expect(cleared.status, CoachMailStatus.empty);
    });

    test('an emptied server response clears the stale cached digest', () async {
      final auth = await signedIn();
      await CoachMailService(
        auth: auth,
        httpClient: MockClient((_) async => jsonOk(digestBody())),
      ).fetch();

      // Coach mail aged out of the server's window — the old summary must not
      // linger on the card.
      await CoachMailService(
        auth: auth,
        httpClient: MockClient(
          (_) async => jsonOk(jsonEncode({'digest': null, 'messages': []})),
        ),
      ).fetch();

      expect((await CoachMailService(auth: auth).loadCached()).digest, isNull);
    });

    test('unreadable cached json is discarded rather than crashing', () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'test-jwt',
        'auth_issued_at': DateTime.now().toIso8601String(),
        'coach_digest': 'not json',
        'coach_messages': 'also not json',
      });
      final auth = AuthService(
        serverBase: 'http://test',
        googleServerClientId: '',
      );
      await auth.load();
      final cached = await CoachMailService(auth: auth).loadCached();
      expect(cached.digest, isNull);
      expect(cached.messages, isEmpty);
    });
  });
}
