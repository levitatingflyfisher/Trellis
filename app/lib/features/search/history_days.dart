/// History's day headings: "Today", "Yesterday", then dates. Local
/// calendar days, not 24 h buckets, so something heard at 23:55 is
/// yesterday's at 00:05.
library;

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String dayLabel(int ms, DateTime now) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final days = _day(now).difference(_day(d)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final base = '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

class DayGroup<T> {
  final String label;
  final List<T> items;
  const DayGroup(this.label, this.items);
}

/// Groups an already-ordered list by its runs of days; the order is the
/// caller's and is never changed here.
List<DayGroup<T>> groupByDay<T>(
    List<T> items, int Function(T) atMs, DateTime now) {
  final groups = <DayGroup<T>>[];
  for (final item in items) {
    final label = dayLabel(atMs(item), now);
    if (groups.isEmpty || groups.last.label != label) {
      groups.add(DayGroup(label, [item]));
    } else {
      groups.last.items.add(item);
    }
  }
  return groups;
}
