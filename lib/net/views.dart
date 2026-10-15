import '../data/models.dart';
import '../data/delivery.dart';
export '../data/delivery.dart';

/// Folded state of mutations (edits, deletes, likes, reactions, votes)
/// over a set of base items. Last write per (actor, target) wins.
class Folded {
  final edited = <String, ({String text, int ts})>{};
  final deleted = <String>{};
  final likes = <String, Set<String>>{};
  final reactions = <String, Map<String, String>>{};
  final votes = <String, Map<String, int>>{};
  final views = <String, Set<String>>{};
  final closedPolls = <String>{};
}

Folded fold(
  Iterable<Item> mutations,
  Map<String, Item> targets, {
  bool Function(String actor, Item target)? canModerate,
}) {
  final f = Folded();
  final sorted = mutations.toList()..sort((a, b) => a.ts.compareTo(b.ts));
  for (final m in sorted) {
    final t = m.e.target;
    if (t == null) continue;
    final target = targets[t];
    switch (m.e.kind) {
      case K.edit:
        if (target != null && target.author == m.author) {
          f.edited[t] = (text: (m.body['text'] as String?) ?? '', ts: m.ts);
        }
        if (m.body['closePoll'] == true && _mayClose(m, target, canModerate)) {
          f.closedPolls.add(t);
        }
      case K.del:
        if (target == null ||
            target.author == m.author ||
            (canModerate?.call(m.author, target) ?? false)) {
          f.deleted.add(t);
        }
      case K.like:
        final s = f.likes.putIfAbsent(t, () => <String>{});
        m.body['on'] == false ? s.remove(m.author) : s.add(m.author);
      case K.react:
        final r = f.reactions.putIfAbsent(t, () => <String, String>{});
        final emoji = m.body['emoji'] as String?;
        if (emoji == null || emoji.isEmpty || m.body['on'] == false) {
          r.remove(m.author);
        } else {
          r[m.author] = emoji;
        }
      case K.vote:
        final v = f.votes.putIfAbsent(t, () => <String, int>{});
        final o = (m.body['option'] as num?)?.toInt();
        o == null ? v.remove(m.author) : v[m.author] = o;
        if (m.body['close'] == true && _mayClose(m, target, canModerate)) {
          f.closedPolls.add(t);
        }
      case K.view:
        f.views.putIfAbsent(t, () => <String>{}).add(m.author);
    }
  }
  return f;
}

bool _mayClose(
  Item mutation,
  Item? target,
  bool Function(String actor, Item target)? canModerate,
) {
  if (target == null) return false;
  if (mutation.author == target.author) return true;
  return canModerate?.call(mutation.author, target) ?? false;
}

class Poll {
  const Poll(
    this.question,
    this.options, {
    this.closesAt,
    this.multi = false,
    this.stopped = false,
  });
  final String question;
  final List<String> options;
  final int? closesAt;
  final bool multi;
  final bool stopped;

  bool get closed =>
      stopped ||
      (closesAt != null && DateTime.now().millisecondsSinceEpoch > closesAt!);

  Map<String, dynamic> toJson() => {
    'q': question,
    'o': options,
    if (closesAt != null) 'c': closesAt,
    if (stopped) 'x': true,
  };

  static Poll? fromJson(Object? j) {
    if (j is! Map) return null;
    final raw = j['o'];
    if (raw is! List || raw.length < 2 || raw.length > 16) return null;
    final options = <String>[];
    for (final option in raw) {
      if (option is! String || option.isEmpty) return null;
      options.add(option);
    }
    final question = j['q'];
    if (question != null && question is! String) return null;
    final closes = j['c'];
    if (closes != null && closes is! num) return null;
    return Poll(
      question is String ? question : '',
      options,
      closesAt: closes is num ? closes.toInt() : null,
      stopped: j['x'] == true,
    );
  }
}

class PollState {
  const PollState(
    this.poll,
    this.counts,
    this.myVote,
    this.total, {
    this.closed = false,
  });
  final Poll poll;
  final List<int> counts;
  final int? myVote;
  final int total;
  final bool closed;
  bool get locked => closed || poll.closed;
}

PollState? pollState(Item item, Folded f, String me) {
  final poll = Poll.fromJson(item.body['poll']);
  if (poll == null) return null;
  final votes = f.votes[item.id] ?? const {};
  final counts = List.filled(poll.options.length, 0);
  for (final v in votes.values) {
    if (v >= 0 && v < counts.length) counts[v]++;
  }
  return PollState(
    poll,
    counts,
    votes[me],
    votes.length,
    closed: f.closedPolls.contains(item.id),
  );
}

/// A post plus everything needed to render it.
class PostView {
  const PostView({
    required this.item,
    required this.text,
    required this.media,
    required this.likes,
    required this.liked,
    required this.comments,
    required this.bookmarked,
    required this.edited,
    this.poll,
    this.repost,
    this.spaceId,
    this.title = '',
    this.boardId,
    this.ai = false,
    this.nsfw = false,
    this.views = 0,
    this.viewers = const [],
    this.channelId,
  });

  final Item item;
  final String text;
  final List<MediaRef> media;
  final int likes;
  final bool liked;
  final int comments;
  final bool bookmarked;
  final bool edited;
  final PollState? poll;
  final Map<String, dynamic>? repost;
  final String? spaceId;
  final String title;
  final String? boardId;
  final bool ai;
  final bool nsfw;
  final int views;

  /// Who viewed it; filled only for your own posts.
  final List<String> viewers;
  final String? channelId;

  String get id => item.id;
  String get author => item.author;
  String get scope => Scope.post(item.author, item.id);
}

class CommentView {
  const CommentView({
    required this.item,
    required this.text,
    required this.likes,
    required this.liked,
    required this.edited,
    this.replyTo,
  });
  final Item item;
  final String text;
  final int likes;
  final bool liked;
  final bool edited;
  final String? replyTo;
}

/// A chat message (DM or channel) plus folded state.
class MessageView {
  const MessageView({
    required this.item,
    required this.text,
    required this.media,
    required this.reactions,
    required this.edited,
    required this.mine,
    this.replyTo,
    this.delivery = Delivery.sent,
    this.recipients = const [],
    this.poll,
    this.expires,
    this.forwarded = false,
    this.nsfw = false,
  });

  final Item item;
  final String text;
  final List<MediaRef> media;
  final Map<String, String> reactions;
  final bool edited;
  final bool mine;
  final MessageView? replyTo;
  final Delivery delivery;
  final List<RecipientDelivery> recipients;
  bool get canRetry => mine && recipients.any((r) => r.canRetry);
  bool get canCancel => mine && recipients.any((r) => r.canCancel);
  final PollState? poll;
  final int? expires;
  final bool forwarded;
  final bool nsfw;

  String get id => item.id;
  String get author => item.author;
  int get ts => item.ts;

  Map<String, int> get reactionCounts {
    final out = <String, int>{};
    for (final e in reactions.values) {
      out[e] = (out[e] ?? 0) + 1;
    }
    return out;
  }
}

class ChatSummary {
  const ChatSummary({
    required this.scope,
    required this.peer,
    required this.last,
    required this.unread,
    required this.pinned,
    required this.muted,
    required this.archived,
    required this.online,
    required this.typing,
    required this.syncMine,
    required this.syncTheirs,
    required this.pendingOffer,
    this.group = false,
    this.title = '',
    this.memberCount = 0,
    this.membersOnline = 0,
    this.broadcast = false,
  });
  final String scope;
  final String peer;
  final MessageView? last;
  final int unread;
  final bool pinned;
  final bool muted;
  final bool archived;
  final bool online;
  final bool typing;
  final GrantState? syncMine;
  final GrantState? syncTheirs;
  final bool pendingOffer;
  final bool group;
  final String title;
  final int memberCount;
  final int membersOnline;
  final bool broadcast;

  int get sortTs => last?.ts ?? 0;
}

class StoryGroup {
  const StoryGroup(this.author, this.stories, this.allSeen);
  final String author;
  final List<Item> stories;
  final bool allSeen;
}

class SyncState {
  const SyncState({
    required this.mine,
    required this.theirs,
    required this.theirsOffered,
  });

  /// My messages kept on the peer's device.
  final GrantState? mine;

  /// Their messages kept on my device.
  final GrantState? theirs;

  /// They asked me to keep theirs and are waiting for my answer.
  final bool theirsOffered;

  bool get bothActive =>
      mine == GrantState.active && theirs == GrantState.active;
}
