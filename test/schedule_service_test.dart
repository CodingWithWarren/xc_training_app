import 'package:flutter_test/flutter_test.dart';
import 'package:xctraining/schedule_service.dart';

/// Wraps [body] in the VCALENDAR envelope a real feed has.
String cal(String body) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$body\r\nEND:VCALENDAR\r\n';

/// A season-length window, so expansion isn't the thing under test unless
/// a case says so.
final _from = DateTime(2026, 8, 1);
final _to = DateTime(2026, 12, 1);

List<ScheduleEvent> parse(String body) =>
    parseIcs(cal(body), from: _from, to: _to);

void main() {
  group('single events', () {
    test('parses summary, start, end and location', () {
      final events = parse('''
BEGIN:VEVENT
UID:meet-1
SUMMARY:Rivertown Invitational
LOCATION:Rivertown Park
DTSTART;TZID=America/New_York:20260912T090000
DTEND;TZID=America/New_York:20260912T113000
END:VEVENT''');

      expect(events, hasLength(1));
      expect(events.single.summary, 'Rivertown Invitational');
      expect(events.single.location, 'Rivertown Park');
      expect(events.single.start, DateTime(2026, 9, 12, 9));
      expect(events.single.end, DateTime(2026, 9, 12, 11, 30));
    });

    test('flags VALUE=DATE events as all-day', () {
      // Midnight here is an artifact of the date-only format, not a real
      // start time — rendering it as "12:00 AM" would be wrong.
      final events = parse('''
BEGIN:VEVENT
UID:meet-allday
SUMMARY:League Meet
DTSTART;VALUE=DATE:20260822
DTEND;VALUE=DATE:20260823
END:VEVENT''');

      expect(events.single.isAllDay, isTrue);
      expect(events.single.start, DateTime(2026, 8, 22));
    });

    test('timed events are not flagged all-day', () {
      final events = parse('''
BEGIN:VEVENT
UID:meet-timed
SUMMARY:Timed Meet
DTSTART;TZID=America/Los_Angeles:20260822T083000
END:VEVENT''');

      expect(events.single.isAllDay, isFalse);
    });

    test('skips cancelled events', () {
      final events = parse('''
BEGIN:VEVENT
UID:meet-2
SUMMARY:Cancelled Meet
STATUS:CANCELLED
DTSTART:20260912T090000
END:VEVENT''');

      expect(events, isEmpty);
    });

    test('drops events outside the window', () {
      final events = parse('''
BEGIN:VEVENT
UID:meet-3
SUMMARY:Next Year
DTSTART:20270912T090000
END:VEVENT''');

      expect(events, isEmpty);
    });

    test('unfolds continuation lines', () {
      // RFC 5545 folds long values onto continuation lines starting with a
      // space; not rejoining them truncates the summary.
      final events = parse(
        'BEGIN:VEVENT\r\n'
        'UID:meet-4\r\n'
        'SUMMARY:League Championship at the Fairgrounds\r\n'
        '  Cross Country Course\r\n'
        'DTSTART:20260912T090000\r\n'
        'END:VEVENT',
      );

      expect(
        events.single.summary,
        'League Championship at the Fairgrounds Cross Country Course',
      );
    });

    test('unescapes commas and newlines', () {
      final events = parse('''
BEGIN:VEVENT
UID:meet-5
SUMMARY:Meet\\, then dinner
DESCRIPTION:Bring spikes\\nand water
DTSTART:20260912T090000
END:VEVENT''');

      expect(events.single.summary, 'Meet, then dinner');
      expect(events.single.description, 'Bring spikes\nand water');
    });
  });

  group('recurrence expansion', () {
    test('weekly BYDAY expands to every listed weekday', () {
      // The whole point: the feed holds ONE event, not 40.
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:XC Practice
DTSTART:20260803T153000
DTEND:20260803T170000
RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;UNTIL=20261031T000000Z
END:VEVENT''');

      expect(events.length, greaterThan(50));
      expect(events.every((e) => e.summary == 'XC Practice'), isTrue);
      expect(events.every((e) => e.start.weekday <= DateTime.friday), isTrue);
      expect(events.every((e) => e.start.hour == 15), isTrue);
      expect(events.every((e) => e.start.minute == 30), isTrue);
    });

    test('carries the master duration onto each occurrence', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:XC Practice
DTSTART:20260803T153000
DTEND:20260803T170000
RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3
END:VEVENT''');

      expect(events, hasLength(3));
      for (final e in events) {
        expect(e.end!.difference(e.start), const Duration(minutes: 90));
      }
    });

    test('honours COUNT', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Practice
DTSTART:20260803T153000
RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4
END:VEVENT''');

      expect(events, hasLength(4));
      expect(events.first.start, DateTime(2026, 8, 3, 15, 30));
      expect(events.last.start, DateTime(2026, 8, 24, 15, 30));
    });

    test('honours UNTIL', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Practice
DTSTART:20260803T153000
RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260825T000000Z
END:VEVENT''');

      expect(events.last.start.isBefore(DateTime(2026, 8, 25)), isTrue);
    });

    test('honours INTERVAL', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Every other Monday
DTSTART:20260803T153000
RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=3
END:VEVENT''');

      expect(events.map((e) => e.start.day), [3, 17, 31]);
    });

    test('daily recurrence', () {
      final events = parse('''
BEGIN:VEVENT
UID:camp
SUMMARY:Camp
DTSTART:20260803T090000
RRULE:FREQ=DAILY;COUNT=5
END:VEVENT''');

      expect(events.map((e) => e.start.day), [3, 4, 5, 6, 7]);
    });

    test('weekly with no BYDAY repeats on the start weekday', () {
      final events = parse('''
BEGIN:VEVENT
UID:lift
SUMMARY:Lifting
DTSTART:20260805T060000
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT''');

      expect(events, hasLength(3));
      expect(
        events.every((e) => e.start.weekday == DateTime.wednesday),
        isTrue,
      );
    });

    test('monthly skips months lacking the day rather than shifting it', () {
      // Jan 31 + 1 month must not silently become Mar 3.
      final events = parseIcs(
        cal('''
BEGIN:VEVENT
UID:monthly
SUMMARY:Monthly
DTSTART:20260131T090000
RRULE:FREQ=MONTHLY;COUNT=3
END:VEVENT'''),
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events.every((e) => e.start.day == 31), isTrue);
    });

    test('unsupported positional BYDAY falls back to one occurrence', () {
      // Better one right date than a series of wrong ones.
      final events = parse('''
BEGIN:VEVENT
UID:booster
SUMMARY:Booster Meeting
DTSTART:20260811T190000
RRULE:FREQ=MONTHLY;BYDAY=2TU
END:VEVENT''');

      expect(events, hasLength(1));
    });
  });

  group('exceptions to a series', () {
    test('EXDATE removes a cancelled practice', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Practice
DTSTART:20260803T153000
RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4
EXDATE:20260810T153000
END:VEVENT''');

      expect(events, hasLength(3));
      expect(events.map((e) => e.start.day), [3, 17, 24]);
    });

    test('a comma-separated EXDATE list removes each date', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Practice
DTSTART:20260803T153000
RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4
EXDATE:20260810T153000,20260817T153000
END:VEVENT''');

      expect(events.map((e) => e.start.day), [3, 24]);
    });

    test('RECURRENCE-ID moves a single occurrence', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Practice
DTSTART:20260803T153000
DTEND:20260803T170000
RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3
END:VEVENT
BEGIN:VEVENT
UID:practice
RECURRENCE-ID:20260810T153000
SUMMARY:Practice (late start)
DTSTART:20260810T163000
DTEND:20260810T180000
END:VEVENT''');

      expect(events, hasLength(3));
      final moved = events.firstWhere((e) => e.start.day == 10);
      expect(moved.start.hour, 16);
      expect(moved.summary, 'Practice (late start)');
    });

    test('a cancelled override drops just that occurrence', () {
      final events = parse('''
BEGIN:VEVENT
UID:practice
SUMMARY:Practice
DTSTART:20260803T153000
RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3
END:VEVENT
BEGIN:VEVENT
UID:practice
RECURRENCE-ID:20260810T153000
STATUS:CANCELLED
DTSTART:20260810T153000
END:VEVENT''');

      expect(events.map((e) => e.start.day), [3, 17]);
    });
  });

  group('date parsing', () {
    test('Z-suffixed values convert from UTC to local', () {
      final utc = parseIcsDate('20260912T140000Z')!;
      expect(utc, DateTime.utc(2026, 9, 12, 14).toLocal());
    });

    test('bare values are read as local wall-clock time', () {
      expect(parseIcsDate('20260912T090000'), DateTime(2026, 9, 12, 9));
    });

    test('date-only values land at midnight', () {
      expect(parseIcsDate('20260912'), DateTime(2026, 9, 12));
    });

    test('a TZID prefix is stripped', () {
      expect(
        parseIcsDate('TZID=America/New_York:20260912T090000'),
        DateTime(2026, 9, 12, 9),
      );
    });

    test('garbage returns null instead of throwing', () {
      expect(parseIcsDate('not-a-date'), isNull);
    });
  });

  group('grouping by week', () {
    ScheduleEvent ev(int day, {String summary = 'practice', int hour = 8}) =>
        ScheduleEvent(
          summary: summary,
          start: DateTime(2026, 8, day, hour, 30),
        );

    test('collapses repeats inside one week', () {
      // Mon-Thu Aug 10-13 are one week.
      final weeks = groupByWeek([ev(10), ev(11), ev(12), ev(13)]);

      expect(weeks, hasLength(1));
      expect(weeks.single.entries, hasLength(1));
      expect(weeks.single.entries.single.starts, hasLength(4));
    });

    test('does not merge the same event across weeks', () {
      // Aug 10 and Aug 17 are consecutive Mondays.
      final weeks = groupByWeek([ev(10), ev(17)]);

      expect(weeks, hasLength(2));
      expect(weeks[0].weekStart, DateTime(2026, 8, 10));
      expect(weeks[1].weekStart, DateTime(2026, 8, 17));
    });

    test('keeps different titles apart in the same week', () {
      final weeks = groupByWeek([
        ev(10),
        ev(14, summary: 'practice at city hall'),
      ]);

      expect(weeks.single.entries, hasLength(2));
    });

    test('keeps different times of day apart', () {
      final weeks = groupByWeek([ev(10), ev(11, hour: 15)]);

      expect(weeks.single.entries, hasLength(2));
    });

    test('weekend events are grouped, not dropped', () {
      final weeks = groupByWeek([
        ev(10),
        ScheduleEvent(
          summary: 'meet',
          start: DateTime(2026, 8, 15),
          isAllDay: true,
        ),
      ]);

      final summaries = weeks.single.entries.map((e) => e.summary);
      expect(summaries, contains('meet'));
    });

    test('weeks come back in chronological order', () {
      final weeks = groupByWeek([ev(24), ev(10), ev(17)]);

      expect(weeks.map((w) => w.weekStart.day), [10, 17, 24]);
    });
  });

  group('compactDayLabel', () {
    DateTime aug(int day) => DateTime(2026, 8, day, 8, 30);

    test('a single occurrence keeps its date', () {
      expect(compactDayLabel([aug(22)]), 'Sat 22');
    });

    test('three or more consecutive days become a range', () {
      expect(compactDayLabel([aug(10), aug(11), aug(12), aug(13)]), 'Mon–Thu');
    });

    test('two consecutive days stay comma-separated', () {
      // "Mon–Tue" is no shorter than "Mon, Tue".
      expect(compactDayLabel([aug(10), aug(11)]), 'Mon, Tue');
    });

    test('non-consecutive days are listed', () {
      expect(compactDayLabel([aug(10), aug(12), aug(14)]), 'Mon, Wed, Fri');
    });

    test('a run plus a straggler mixes both forms', () {
      expect(
        compactDayLabel([aug(10), aug(11), aug(12), aug(15)]),
        'Mon–Wed, Sat',
      );
    });

    test('empty input is empty', () {
      expect(compactDayLabel([]), '');
    });
  });

  test('events come back sorted by start', () {
    final events = parse('''
BEGIN:VEVENT
UID:b
SUMMARY:Later
DTSTART:20260920T090000
END:VEVENT
BEGIN:VEVENT
UID:a
SUMMARY:Earlier
DTSTART:20260912T090000
END:VEVENT''');

    expect(events.map((e) => e.summary), ['Earlier', 'Later']);
  });
}
