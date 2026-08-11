import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Team schedule (practices + meets) read from a Google Calendar iCal feed.
///
/// **No widgets or BuildContext** — same rule as `sync_service.dart`, so this
/// stays unit-testable without a device and could be moved to a background
/// isolate later.
///
/// The feed URL comes from `--dart-define=SCHEDULE_ICS_URL=...` (see
/// `config/dev.json.example`). Empty disables the feature and the Training
/// tab simply omits the schedule card.
///
/// ## Why iCal and not the Calendar API
///
/// The schedule is identical for every athlete, so per-user OAuth buys
/// nothing and would drag in Google's `calendar.readonly` scope — which
/// Google classifies as *sensitive* and gates behind app verification.
/// A read-only iCal feed needs no scope at all.
///
/// The tradeoff: **Google refreshes the published iCal feed lazily**, so
/// calendar edits can take hours to appear here. Accepted deliberately —
/// the coach announces changes by email/in person anyway.
///
/// ## Timezones
///
/// Times carrying a `TZID` (the usual Google Calendar output) are read as
/// **local wall-clock time**. Resolving `TZID` properly needs a full tz
/// database, which isn't worth a dependency for a team whose phones sit in
/// the same timezone as the calendar. Times stamped `Z` are true UTC and
/// convert exactly.

/// One occurrence on the schedule. A recurring practice expands into many
/// of these, one per date.
class ScheduleEvent {
  const ScheduleEvent({
    required this.summary,
    required this.start,
    this.end,
    this.location,
    this.description,
    this.isAllDay = false,
  });

  final String summary;
  final DateTime start;
  final DateTime? end;
  final String? location;
  final String? description;

  /// `DTSTART;VALUE=DATE` — a date with no clock time. [start] is midnight,
  /// which the UI must not render as "12:00 AM".
  final bool isAllDay;

  @override
  String toString() => 'ScheduleEvent($summary @ $start)';
}

/// Outcome of a [ScheduleService.load]. Carries [events] *and* the context
/// the UI needs to be honest about them — whether they came from the cache
/// and, if the network failed, why.
class ScheduleResult {
  const ScheduleResult({
    required this.events,
    this.fetchedAt,
    this.fromCache = false,
    this.error,
  });

  final List<ScheduleEvent> events;

  /// When the underlying feed was downloaded (not when it was parsed).
  final DateTime? fetchedAt;

  /// True when the network fetch failed and [events] came from the last
  /// good download instead.
  final bool fromCache;

  /// Human-readable failure, or null. Non-null with a non-empty [events]
  /// means "showing stale data" — surface both.
  final String? error;

  bool get isEmpty => events.isEmpty;
}

/// shared_preferences keys — the raw feed body and its download time, kept
/// so the schedule still renders with no connectivity.
const String scheduleCachePrefsKey = 'schedule_ics_cache';
const String scheduleCacheAtPrefsKey = 'schedule_ics_cached_at';

class ScheduleService {
  ScheduleService({required this.icsUrl, http.Client? client})
    : _client = client ?? http.Client();

  /// iCal feed URL. Empty disables the feature entirely.
  final String icsUrl;

  final http.Client _client;

  bool get isConfigured => icsUrl.isNotEmpty;

  /// How far ahead the schedule is materialised. Recurring practices are
  /// otherwise unbounded, so expansion needs a horizon.
  static const Duration lookahead = Duration(days: 120);

  /// How far back to keep events. A full week, so a collapsed entry holds
  /// its shape as the week progresses: a Mon–Wed block still reads "Mon–Wed"
  /// when viewed on Wednesday instead of shrinking day by day as
  /// occurrences drop out of the window. Hiding what's finished is
  /// [dropPastEntries]' job, at whole-entry granularity.
  static const Duration lookbehind = Duration(days: 7);

  /// Download, parse, and expand the feed. Falls back to the cached copy
  /// when the network fails, so this only returns an empty list when
  /// there is genuinely nothing to show.
  Future<ScheduleResult> load({DateTime? now}) async {
    final at = now ?? DateTime.now();
    if (!isConfigured) {
      return const ScheduleResult(
        events: [],
        error:
            'Schedule is not configured. Set SCHEDULE_ICS_URL via '
            '--dart-define (see CLAUDE.md "Team schedule").',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    // A background isolate may have refreshed the cache; without reload()
    // this isolate keeps serving its own stale in-process copy.
    await prefs.reload();

    try {
      final response = await _client
          .get(Uri.parse(icsUrl))
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return _cachedOr(
          prefs,
          at,
          'Schedule feed returned ${response.statusCode}.',
        );
      }

      // Feeds are UTF-8 but rarely say so, and http defaults to latin1
      // when the charset is absent — which mangles anything non-ASCII.
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (!body.contains('BEGIN:VCALENDAR')) {
        return _cachedOr(
          prefs,
          at,
          'That URL did not return a calendar feed. Check it is the '
          '"iCal format" address, not the calendar\'s web page.',
        );
      }

      await prefs.setString(scheduleCachePrefsKey, body);
      await prefs.setString(scheduleCacheAtPrefsKey, at.toIso8601String());

      return ScheduleResult(
        events: parseIcs(
          body,
          from: at.subtract(lookbehind),
          to: at.add(lookahead),
        ),
        fetchedAt: at,
      );
    } catch (e) {
      return _cachedOr(prefs, at, 'Could not reach the schedule feed: $e');
    }
  }

  /// Serve the last good download, tagged with [error] so the UI can say
  /// the data is stale rather than silently pretending it's fresh.
  ScheduleResult _cachedOr(
    SharedPreferences prefs,
    DateTime now,
    String error,
  ) {
    final cached = prefs.getString(scheduleCachePrefsKey);
    if (cached == null) return ScheduleResult(events: const [], error: error);

    final iso = prefs.getString(scheduleCacheAtPrefsKey);
    return ScheduleResult(
      events: parseIcs(
        cached,
        from: now.subtract(lookbehind),
        to: now.add(lookahead),
      ),
      fetchedAt: iso != null ? DateTime.tryParse(iso) : null,
      fromCache: true,
      error: error,
    );
  }
}

// ---------------------------------------------------------------------------
// Grouping for display
// ---------------------------------------------------------------------------

/// Repeats of one event inside a single week, collapsed into one row —
/// "practice, Mon–Thu, 8:30 AM" instead of four near-identical lines.
class ScheduleEntry {
  ScheduleEntry({
    required this.summary,
    required this.starts,
    this.location,
    this.isAllDay = false,
  });

  final String summary;
  final String? location;
  final bool isAllDay;

  /// Every occurrence in this week, ascending. Length 1 for a one-off.
  final List<DateTime> starts;

  DateTime get first => starts.first;
}

/// One week's worth of entries. [weekStart] is the Monday.
class ScheduleWeek {
  ScheduleWeek({required this.weekStart, required this.entries});

  final DateTime weekStart;
  final List<ScheduleEntry> entries;
}

/// Bucket [events] by week, collapsing repeats **within** each week.
///
/// Deliberately does not merge across weeks: a practice block that changes
/// mid-season should read as a different week, not silently fold into the
/// one before it. Two occurrences collapse only when title, location, time
/// of day and all-day flag all match.
List<ScheduleWeek> groupByWeek(List<ScheduleEvent> events) {
  final byWeek = <DateTime, Map<String, ScheduleEntry>>{};

  for (final e in events) {
    final d = e.start;
    // Monday of this event's week. Built from calendar fields so a DST
    // boundary can't push an event into the neighbouring week.
    final monday = DateTime(d.year, d.month, d.day - (d.weekday - 1));
    final key = e.isAllDay
        ? '${e.summary}|${e.location}|allday'
        : '${e.summary}|${e.location}|${d.hour}:${d.minute}';

    final week = byWeek.putIfAbsent(monday, () => {});
    final existing = week[key];
    if (existing == null) {
      week[key] = ScheduleEntry(
        summary: e.summary,
        location: e.location,
        isAllDay: e.isAllDay,
        starts: [e.start],
      );
    } else {
      existing.starts.add(e.start);
    }
  }

  final weeks = byWeek.keys.toList()..sort();
  return [
    for (final w in weeks)
      ScheduleWeek(
        weekStart: w,
        entries: byWeek[w]!.values.toList()
          ..sort((a, b) => a.first.compareTo(b.first)),
      ),
  ];
}

/// Drop entries that are entirely in the past, plus any week left empty.
///
/// Granularity is the whole entry, never the individual occurrence: a
/// Mon–Wed practice block still reads "Mon–Wed" on Tuesday and Wednesday
/// and vanishes only on Thursday. Trimming occurrence-by-occurrence would
/// relabel it mid-week — "Tue–Wed", then "Wed" — which reads as the coach
/// having changed the schedule rather than as time passing.
///
/// Anything today survives regardless of the clock, so this morning's
/// practice is still listed this afternoon.
List<ScheduleWeek> dropPastEntries(List<ScheduleWeek> weeks, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final out = <ScheduleWeek>[];

  for (final w in weeks) {
    final kept = [
      for (final e in w.entries)
        if (e.starts.any((s) => !s.isBefore(today))) e,
    ];
    if (kept.isNotEmpty) {
      out.add(ScheduleWeek(weekStart: w.weekStart, entries: kept));
    }
  }
  return out;
}

const List<String> _dayNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Day label for a collapsed entry: `Mon–Thu`, `Mon, Wed, Fri`, or `Sat 22`
/// for a single occurrence — a one-off meet is worth pinning to a date,
/// where a recurring block reads better as a span.
String compactDayLabel(List<DateTime> starts) {
  if (starts.isEmpty) return '';
  if (starts.length == 1) {
    final d = starts.first;
    return '${_dayNames[d.weekday - 1]} ${d.day}';
  }

  final days = starts.map((d) => d.weekday).toSet().toList()..sort();

  // Collapse consecutive weekdays into runs; 3+ becomes a dashed range,
  // anything shorter stays comma-separated (a "Mon–Tue" range saves nothing).
  final parts = <String>[];
  var runStart = 0;
  for (var i = 1; i <= days.length; i++) {
    if (i < days.length && days[i] == days[i - 1] + 1) continue;
    final runLength = i - runStart;
    if (runLength >= 3) {
      parts.add(
        '${_dayNames[days[runStart] - 1]}–${_dayNames[days[i - 1] - 1]}',
      );
    } else {
      for (var j = runStart; j < i; j++) {
        parts.add(_dayNames[days[j] - 1]);
      }
    }
    runStart = i;
  }
  return parts.join(', ');
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse an iCal document into the concrete occurrences falling within
/// [from]..[to], sorted by start time.
///
/// Recurring events are *expanded* here: the feed stores one VEVENT plus an
/// `RRULE`, and this turns that into one [ScheduleEvent] per date. Skipping
/// that step is the classic iCal bug — the schedule renders fine but shows
/// a single practice, because the other occurrences were never in the file
/// to begin with.
List<ScheduleEvent> parseIcs(
  String ics, {
  required DateTime from,
  required DateTime to,
}) {
  final raw = _parseVEvents(ics);

  // Events carrying RECURRENCE-ID replace one specific occurrence of their
  // parent series ("practice moved to 4pm, but only this Tuesday").
  final overrides = <String, _RawEvent>{};
  final masters = <_RawEvent>[];
  for (final e in raw) {
    if (e.recurrenceId != null && e.uid != null) {
      overrides['${e.uid}|${_key(e.recurrenceId!)}'] = e;
    } else {
      masters.add(e);
    }
  }

  final out = <ScheduleEvent>[];
  for (final m in masters) {
    if (m.start == null || m.cancelled) continue;

    final starts = m.rrule == null
        ? [m.start!]
        : expandRecurrence(
            start: m.start!,
            rule: m.rrule!,
            windowStart: from,
            windowEnd: to,
          );

    for (final s in starts) {
      if (m.exDates.contains(_key(s))) continue;

      // An override may move the occurrence outside the window, or be a
      // cancellation of just that date.
      final override = overrides['${m.uid}|${_key(s)}'];
      if (override != null && override.cancelled) continue;

      final start = override?.start ?? s;
      if (start.isBefore(from) || start.isAfter(to)) continue;

      final duration = m.end != null && m.start != null
          ? m.end!.difference(m.start!)
          : null;

      out.add(
        ScheduleEvent(
          summary: override?.summary ?? m.summary ?? 'Untitled',
          start: start,
          end: override?.end ?? (duration != null ? start.add(duration) : null),
          location: override?.location ?? m.location,
          description: override?.description ?? m.description,
          isAllDay: m.allDay,
        ),
      );
    }
  }

  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Occurrence identity for EXDATE / RECURRENCE-ID matching. Compared to the
/// minute: feeds are inconsistent about seconds, and no schedule has two
/// occurrences of the same series inside one minute.
String _key(DateTime d) =>
    '${d.year}-${d.month}-${d.day}-${d.hour}-${d.minute}';

/// Turn one VEVENT + its RRULE into the concrete start times landing in
/// [windowStart]..[windowEnd].
///
/// Supports the rules a school practice schedule actually uses: DAILY,
/// WEEKLY (with BYDAY), MONTHLY and YEARLY, each with INTERVAL, COUNT and
/// UNTIL. Positional forms (`BYDAY=2TU`, "second Tuesday") are not
/// expanded — an unsupported rule yields just the first occurrence rather
/// than wrong dates.
List<DateTime> expandRecurrence({
  required DateTime start,
  required Map<String, String> rule,
  required DateTime windowStart,
  required DateTime windowEnd,
}) {
  final freq = rule['FREQ']?.toUpperCase();
  if (freq == null) return [start];

  final interval = int.tryParse(rule['INTERVAL'] ?? '1') ?? 1;
  final count = int.tryParse(rule['COUNT'] ?? '');
  final until = rule['UNTIL'] != null ? parseIcsDate(rule['UNTIL']!) : null;

  // Bail on positional BYDAY rather than silently emitting wrong dates.
  final byDayRaw = rule['BYDAY']
      ?.split(',')
      .map((s) => s.trim().toUpperCase())
      .where((s) => s.isNotEmpty)
      .toList();
  if (byDayRaw != null && byDayRaw.any((d) => !_weekdays.containsKey(d))) {
    return [start];
  }

  final results = <DateTime>[];
  var emitted = 0;

  // Every candidate is rebuilt from calendar fields rather than by adding a
  // Duration, so a DST change mid-season can't drift practice to 14:30.
  bool accept(DateTime occ) {
    if (occ.isBefore(start)) return true; // before the series began
    if (until != null && occ.isAfter(until)) return false;
    if (count != null && emitted >= count) return false;
    emitted++;
    if (!occ.isBefore(windowStart) && !occ.isAfter(windowEnd)) {
      results.add(occ);
    }
    return true;
  }

  // Hard ceiling so a malformed rule can't spin forever.
  const maxSteps = 5000;

  if (freq == 'WEEKLY') {
    final days = (byDayRaw == null || byDayRaw.isEmpty)
        ? [start.weekday]
        : (byDayRaw.map((d) => _weekdays[d]!).toList()..sort());

    // Monday of the week DTSTART falls in.
    var anchor = DateTime(
      start.year,
      start.month,
      start.day - (start.weekday - DateTime.monday),
    );

    for (var step = 0; step < maxSteps; step++) {
      for (final wd in days) {
        final occ = DateTime(
          anchor.year,
          anchor.month,
          anchor.day + (wd - DateTime.monday),
          start.hour,
          start.minute,
          start.second,
        );
        if (!accept(occ)) return results;
      }
      anchor = DateTime(anchor.year, anchor.month, anchor.day + 7 * interval);
      if (anchor.isAfter(windowEnd)) break;
    }
    return results;
  }

  for (var step = 0; step < maxSteps; step++) {
    final DateTime occ;
    switch (freq) {
      case 'DAILY':
        occ = DateTime(
          start.year,
          start.month,
          start.day + step * interval,
          start.hour,
          start.minute,
          start.second,
        );
      case 'MONTHLY':
        occ = DateTime(
          start.year,
          start.month + step * interval,
          start.day,
          start.hour,
          start.minute,
          start.second,
        );
      case 'YEARLY':
        occ = DateTime(
          start.year + step * interval,
          start.month,
          start.day,
          start.hour,
          start.minute,
          start.second,
        );
      default:
        return [start];
    }

    // DateTime normalises overflow, so Jan 31 + 1 month lands in March.
    // RFC 5545 says skip those, not shift them.
    if (freq != 'DAILY' && occ.day != start.day) continue;

    if (!accept(occ)) return results;
    if (occ.isAfter(windowEnd)) break;
  }

  return results;
}

const Map<String, int> _weekdays = {
  'MO': DateTime.monday,
  'TU': DateTime.tuesday,
  'WE': DateTime.wednesday,
  'TH': DateTime.thursday,
  'FR': DateTime.friday,
  'SA': DateTime.saturday,
  'SU': DateTime.sunday,
};

/// A VEVENT as it appears in the file, before recurrence expansion.
class _RawEvent {
  String? uid;
  String? summary;
  String? location;
  String? description;
  DateTime? start;
  DateTime? end;
  DateTime? recurrenceId;
  Map<String, String>? rrule;
  bool cancelled = false;
  bool allDay = false;
  final Set<String> exDates = {};
}

List<_RawEvent> _parseVEvents(String ics) {
  final events = <_RawEvent>[];
  _RawEvent? current;

  for (final line in _unfold(ics)) {
    if (line == 'BEGIN:VEVENT') {
      current = _RawEvent();
      continue;
    }
    if (line == 'END:VEVENT') {
      if (current != null) events.add(current);
      current = null;
      continue;
    }
    if (current == null) continue;

    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final head = line.substring(0, colon);
    final value = line.substring(colon + 1);

    final semi = head.indexOf(';');
    final name = (semi < 0 ? head : head.substring(0, semi)).toUpperCase();

    switch (name) {
      case 'UID':
        current.uid = value;
      case 'SUMMARY':
        current.summary = _unescape(value);
      case 'LOCATION':
        current.location = _unescape(value);
      case 'DESCRIPTION':
        current.description = _unescape(value);
      case 'DTSTART':
        current.start = parseIcsDate(value);
        // VALUE=DATE means an all-day event; the parsed time is midnight
        // rather than a real start.
        current.allDay = head.toUpperCase().contains('VALUE=DATE');
      case 'DTEND':
        current.end = parseIcsDate(value);
      case 'RECURRENCE-ID':
        current.recurrenceId = parseIcsDate(value);
      case 'RRULE':
        current.rrule = _parseRuleParts(value);
      case 'EXDATE':
        // One EXDATE line may carry a comma-separated list.
        for (final d in value.split(',')) {
          final parsed = parseIcsDate(d);
          if (parsed != null) current.exDates.add(_key(parsed));
        }
      case 'STATUS':
        current.cancelled = value.toUpperCase() == 'CANCELLED';
    }
  }

  return events;
}

/// Undo RFC 5545 line folding: a CRLF followed by a space or tab is a
/// continuation of the previous line, not a new one. Long SUMMARY and
/// DESCRIPTION values are routinely folded, so skipping this truncates them.
List<String> _unfold(String ics) {
  final out = <String>[];
  for (final line in const LineSplitter().convert(ics)) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (out.isNotEmpty) out[out.length - 1] += line.substring(1);
    } else {
      out.add(line.trimRight());
    }
  }
  return out;
}

Map<String, String> _parseRuleParts(String value) {
  final parts = <String, String>{};
  for (final chunk in value.split(';')) {
    final eq = chunk.indexOf('=');
    if (eq < 0) continue;
    parts[chunk.substring(0, eq).toUpperCase()] = chunk.substring(eq + 1);
  }
  return parts;
}

String _unescape(String v) => v
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\N', '\n')
    .replaceAll(r'\,', ',')
    .replaceAll(r'\;', ';')
    .replaceAll(r'\\', r'\');

/// Parse an iCal date or date-time. Accepts `YYYYMMDD`,
/// `YYYYMMDDTHHMMSS` and `YYYYMMDDTHHMMSSZ`. Anything with a `TZID`
/// parameter arrives here as the bare value and is read as local time —
/// see the timezone note at the top of this file.
DateTime? parseIcsDate(String value) {
  // Drop any leftover parameter prefix (e.g. "TZID=America/New_York:").
  final colon = value.lastIndexOf(':');
  final v = (colon >= 0 ? value.substring(colon + 1) : value).trim();

  final m = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$',
  ).firstMatch(v);
  if (m == null) return null;

  int g(int i) => int.parse(m.group(i)!);
  final hasTime = m.group(4) != null;

  if (hasTime && m.group(7) == 'Z') {
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6)).toLocal();
  }
  return DateTime(
    g(1),
    g(2),
    g(3),
    hasTime ? g(4) : 0,
    hasTime ? g(5) : 0,
    hasTime ? g(6) : 0,
  );
}
