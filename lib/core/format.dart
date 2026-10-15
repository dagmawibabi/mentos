import 'package:intl/intl.dart';

String timeAgo(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 45) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return t.year == DateTime.now().year ? DateFormat('MMM d').format(t) : DateFormat('MMM d, y').format(t);
}

String clock(int ms) => DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));

String dayLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat('EEEE').format(t);
  return t.year == now.year ? DateFormat('EEEE, MMM d').format(t) : DateFormat('MMM d, y').format(t);
}

String lastSeen(int ms) {
  if (ms == 0) return 'not seen yet';
  final ago = timeAgo(ms);
  return ago == 'now' ? 'seen just now' : 'seen $ago ago';
}

String bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(n < 10240 ? 1 : 0)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String speed(int bps) => bps <= 0 ? '—' : '${bytes(bps)}/s';

String duration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String ttlLabel(int seconds) => switch (seconds) {
      0 => 'Off',
      < 3600 => '${seconds ~/ 60} min',
      < 86400 => '${seconds ~/ 3600} h',
      < 604800 => '${seconds ~/ 86400} d',
      _ => '${seconds ~/ 604800} w',
    };

String compact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  return '${(n / 1000000).toStringAsFixed(1)}m';
}
