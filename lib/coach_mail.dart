// Coach-email digest — client side.
//
// The server owns this feature end to end: it polls the mailbox the athlete
// forwards coach email into, summarizes what it finds, and serves the result
// per-athlete. The app only fetches and renders. That keeps the mailbox
// credentials and the model API key on the server (never in a binary anyone
// can unzip), summarizes each email once for the whole team instead of once
// per device, and means the phone spends one small HTTPS GET.
//
// Endpoints — see docs/SERVER_SCHEMA.md "Coach email digest":
//   GET  /coach-digest          cached digest + the emails behind it
//   POST /coach-digest/refresh  re-poll the mailbox now, same response shape
//
// The card is entirely hidden until the server implements this: a 404 (or a
// 501) reads as "feature not deployed" rather than an error, so this ships
// safely against today's server and lights up on its own once the endpoint
// exists — no app update needed.
//
// No widgets or BuildContext here, matching sync_service.dart, so the logic
// stays unit-testable.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'sync_service.dart' show serverBase;

/// How long the app waits on the digest endpoint. Short: this is decoration on
/// a page that has to render anyway, so a slow server degrades to the cached
/// copy rather than holding the tab up.
const Duration coachDigestTimeout = Duration(seconds: 20);

/// A forced refresh makes the server go out to the mailbox and call the model,
/// so it gets a much longer budget than the cached read.
const Duration coachRefreshTimeout = Duration(seconds: 90);

const String _digestPrefsKey = 'coach_digest';
const String _messagesPrefsKey = 'coach_messages';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// One email behind the digest, as the server hands it over.
class CoachMessage {
  const CoachMessage({
    required this.id,
    required this.from,
    required this.subject,
    required this.date,
    required this.body,
    this.fromName = '',
  });

  factory CoachMessage.fromJson(Map<String, dynamic> json) => CoachMessage(
    id: json['id'] as String? ?? '',
    from: json['from'] as String? ?? '',
    fromName: json['from_name'] as String? ?? '',
    subject: json['subject'] as String? ?? '(no subject)',
    date:
        DateTime.tryParse(json['date'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    body: json['body'] as String? ?? '',
  );

  /// Server-assigned and stable across refreshes (the mail `Message-ID` in
  /// practice). Only used to key the list.
  final String id;
  final String from;
  final String fromName;
  final String subject;
  final DateTime date;
  final String body;

  String get displaySender => fromName.isNotEmpty ? fromName : from;

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from,
    'from_name': fromName,
    'subject': subject,
    'date': date.toIso8601String(),
    'body': body,
  };
}

/// The server's summary of recent coach email.
class CoachDigest {
  const CoachDigest({
    required this.headline,
    required this.bullets,
    required this.actions,
    required this.generatedAt,
    required this.sourceCount,
  });

  factory CoachDigest.fromJson(Map<String, dynamic> json) => CoachDigest(
    headline: (json['headline'] as Object?)?.toString().trim() ?? '',
    bullets: _stringList(json['bullets']),
    actions: _stringList(json['actions']),
    generatedAt:
        DateTime.tryParse(json['generated_at'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    sourceCount: (json['source_count'] as num?)?.toInt() ?? 0,
  );

  /// One sentence: the single most important thing the coach said.
  final String headline;

  /// Short factual points — practice times, meet logistics, workout details.
  final List<String> bullets;

  /// Things the athlete has to *do*, with dates where the email gave one.
  final List<String> actions;

  /// When the server generated this summary (not when the app fetched it).
  final DateTime generatedAt;

  /// How many emails it was built from.
  final int sourceCount;

  bool get isEmpty => headline.isEmpty && bullets.isEmpty && actions.isEmpty;

  Map<String, dynamic> toJson() => {
    'headline': headline,
    'bullets': bullets,
    'actions': actions,
    'generated_at': generatedAt.toIso8601String(),
    'source_count': sourceCount,
  };

  static List<String> _stringList(Object? raw) => raw is List
      ? [
          for (final e in raw)
            if (e != null && e.toString().trim().isNotEmpty)
              e.toString().trim(),
        ]
      : const [];
}

enum CoachMailStatus {
  /// The server doesn't serve this endpoint (404/501), or nobody is signed in.
  /// The caller renders nothing at all — not an error state.
  notConfigured,

  /// Fetched successfully.
  ok,

  /// Endpoint is live but has nothing to show yet — no mail linked, or no
  /// coach email in the server's window.
  empty,

  /// Something failed. [CoachMailResult.message] says what, and any cached
  /// digest rides along so the card degrades instead of blanking.
  error,
}

class CoachMailResult {
  const CoachMailResult({
    required this.status,
    this.message = '',
    this.digest,
    this.messages = const [],
  });

  final CoachMailStatus status;

  /// Human-readable error, surfaced on the card. Empty when [status] is ok.
  final String message;
  final CoachDigest? digest;
  final List<CoachMessage> messages;
}

/// Parses the shared response body of both endpoints. Pure, so the wire
/// contract is unit-tested without a server.
///
/// ```json
/// {"digest": {...} | null, "messages": [ ... ]}
/// ```
CoachMailResult parseDigestResponse(String body) {
  final json = jsonDecode(body) as Map<String, dynamic>;
  final rawDigest = json['digest'];
  final digest = rawDigest is Map
      ? CoachDigest.fromJson(rawDigest.cast<String, dynamic>())
      : null;
  final rawMessages = json['messages'];
  final messages = rawMessages is List
      ? [
          for (final e in rawMessages)
            if (e is Map) CoachMessage.fromJson(e.cast<String, dynamic>()),
        ]
      : const <CoachMessage>[];
  // A digest with nothing in it is "empty", not a summary of nothing — the
  // card should say so rather than render a blank headline.
  final hasContent = (digest != null && !digest.isEmpty) || messages.isNotEmpty;
  return CoachMailResult(
    status: hasContent ? CoachMailStatus.ok : CoachMailStatus.empty,
    digest: digest != null && !digest.isEmpty ? digest : null,
    messages: messages,
  );
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Fetches the coach digest from the server and caches the last good copy.
class CoachMailService {
  CoachMailService({required this.auth, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final AuthService auth;
  final http.Client _http;

  /// Set once the server has answered 404/501 — the endpoint isn't deployed,
  /// so every later call short-circuits instead of re-probing on each refresh.
  bool _unavailable = false;

  /// True once the server has told us it doesn't implement the digest.
  bool get isUnavailable => _unavailable;

  /// Reads the server's cached digest. Cheap — safe on every app open.
  Future<CoachMailResult> fetch() => _request(
    method: 'GET',
    path: '/coach-digest',
    timeout: coachDigestTimeout,
  );

  /// Asks the server to re-poll the mailbox and re-summarize now. Backs the
  /// Settings → "Re-summarize" button.
  Future<CoachMailResult> refresh() => _request(
    method: 'POST',
    path: '/coach-digest/refresh',
    timeout: coachRefreshTimeout,
  );

  Future<CoachMailResult> _request({
    required String method,
    required String path,
    required Duration timeout,
  }) async {
    if (_unavailable || !auth.isSignedIn) {
      return const CoachMailResult(status: CoachMailStatus.notConfigured);
    }

    final cached = await loadCached();
    final uri = Uri.parse('$serverBase$path');
    http.Response response;
    try {
      final request = method == 'POST'
          ? _http.post(uri, headers: auth.authHeaders)
          : _http.get(uri, headers: auth.authHeaders);
      response = await request.timeout(timeout);
    } catch (e) {
      return CoachMailResult(
        status: CoachMailStatus.error,
        message: _friendlyError(e),
        digest: cached.digest,
        messages: cached.messages,
      );
    }

    // 404/501 = this server build predates the feature. Hide the card rather
    // than showing an error for something the athlete can't act on.
    if (response.statusCode == 404 || response.statusCode == 501) {
      _unavailable = true;
      return const CoachMailResult(status: CoachMailStatus.notConfigured);
    }

    // Same contract as the sync client: a rejected token is dropped so the
    // sign-in card comes back.
    if (response.statusCode == 401) {
      await auth.invalidate();
      return CoachMailResult(
        status: CoachMailStatus.error,
        message: 'Sign-in expired. Please sign in again.',
        digest: cached.digest,
        messages: cached.messages,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return CoachMailResult(
        status: CoachMailStatus.error,
        message: 'Server returned ${response.statusCode}.',
        digest: cached.digest,
        messages: cached.messages,
      );
    }

    CoachMailResult parsed;
    try {
      parsed = parseDigestResponse(response.body);
    } catch (e) {
      return CoachMailResult(
        status: CoachMailStatus.error,
        message: 'Could not read the digest: $e',
        digest: cached.digest,
        messages: cached.messages,
      );
    }

    await _save(parsed);
    return parsed;
  }

  /// The last digest the server sent, so the card paints immediately on launch
  /// and still says something useful with no network.
  Future<CoachMailResult> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    CoachDigest? digest;
    final rawDigest = prefs.getString(_digestPrefsKey);
    if (rawDigest != null) {
      try {
        digest = CoachDigest.fromJson(
          jsonDecode(rawDigest) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('[coach] dropping unreadable cached digest: $e');
      }
    }
    var messages = const <CoachMessage>[];
    final rawMessages = prefs.getString(_messagesPrefsKey);
    if (rawMessages != null) {
      try {
        messages = [
          for (final e in jsonDecode(rawMessages) as List)
            CoachMessage.fromJson((e as Map).cast<String, dynamic>()),
        ];
      } catch (e) {
        debugPrint('[coach] dropping unreadable cached messages: $e');
      }
    }
    return CoachMailResult(
      status: digest == null && messages.isEmpty
          ? CoachMailStatus.empty
          : CoachMailStatus.ok,
      digest: digest,
      messages: messages,
    );
  }

  /// Drops the local copy (Settings → "Clear"). The server keeps its own.
  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_digestPrefsKey);
    await prefs.remove(_messagesPrefsKey);
  }

  Future<void> _save(CoachMailResult result) async {
    final prefs = await SharedPreferences.getInstance();
    final digest = result.digest;
    if (digest != null) {
      await prefs.setString(_digestPrefsKey, jsonEncode(digest.toJson()));
    } else {
      await prefs.remove(_digestPrefsKey);
    }
    await prefs.setString(
      _messagesPrefsKey,
      jsonEncode([for (final m in result.messages) m.toJson()]),
    );
  }
}

String _friendlyError(Object e) {
  final text = e.toString();
  if (text.contains('TimeoutException')) {
    return 'The server took too long to answer.';
  }
  if (text.contains('SocketException') || text.contains('ClientException')) {
    return 'Could not reach the server — check your connection.';
  }
  return 'Digest error: ${text.length <= 200 ? text : '${text.substring(0, 200)}…'}';
}
