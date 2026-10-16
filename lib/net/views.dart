import '../data/models.dart';
import '../data/delivery.dart';
import 'link_preview.dart';
import 'live_loc.dart';
export '../data/delivery.dart';

/// Folded state of mutations (edits, deletes, likes, reactions, votes)
/// over a set of base items. Last write per (actor, target) wins.
class Folded {
  final edited = <String, ({String text, int ts})>{};
  final locs = <String, Map<String, dynamic>>{};
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
          final text = m.body['text'];
          if (text is String) {
            f.edited[t] = (text: text, ts: m.ts);
          }
          final loc = m.body['loc'];
          if (loc is Map) {
            final next = Map<String, dynamic>.from(loc);
            final ts = (next['ts'] as num?)?.toInt() ?? m.ts;
            final prevTs = (f.locs[t]?['ts'] as num?)?.toInt() ?? -1;
            if (ts >= prevTs) f.locs[t] = next;
          }
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
    this.likers = const [],
    this.channelId,
    this.preview,
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

  /// Who liked it; filled only for your own posts.
  final List<String> likers;
  final String? channelId;
  final LinkPreview? preview;

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
    this.media = const [],
  });
  final Item item;
  final String text;
  final int likes;
  final bool liked;
  final bool edited;
  final String? replyTo;
  final List<MediaRef> media;
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
    this.hops = const [],
    this.loc,
    this.preview,
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

  /// Recorded hop-by-hop path for this message. Empty until a send or receive saved one.
  final List<String> hops;

  /// Latest GPS fix when this message is a live location.
  final LiveFix? loc;

  /// Open Graph card embedded by the sender, when the text contains that link.
  final LinkPreview? preview;

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

/// A post that has not gone out yet: a draft, or one waiting for its time.
class HeldPost {
  const HeldPost({
    required this.id,
    required this.text,
    required this.at,
    this.title = '',
    this.ai = false,
    this.nsfw = false,
    this.ad = false,
    this.keep = true,
    this.spaceId,
    this.boardId,
    this.channelId,
    this.bcastId,
    this.repost,
    this.poll,
  });

  final String id;
  final String text;
  final String title;

  /// When a draft was last saved, or when a scheduled post should publish.
  final int at;
  final bool ai;
  final bool nsfw;
  final bool ad;
  final bool keep;
  final String? spaceId;
  final String? boardId;
  final String? channelId;
  final String? bcastId;
  final Map<String, dynamic>? repost;
  final Poll? poll;

  /// Stable handle for rows saved before they had an id.
  String get key => id.isNotEmpty ? id : '$at:${text.hashCode}';

  bool get hasBody =>
      text.trim().isNotEmpty ||
      title.trim().isNotEmpty ||
      (poll != null && poll!.options.length >= 2);

  String get preview {
    if (text.trim().isNotEmpty) return text.trim();
    if (title.trim().isNotEmpty) return title.trim();
    final q = poll?.question.trim() ?? '';
    if (q.isNotEmpty) return q;
    if (poll != null) return 'Poll';
    if (repost != null) return 'Repost';
    return 'Empty post';
  }

  HeldPost copyWith({String? id, int? at, String? text, String? title}) =>
      HeldPost(
        id: id ?? this.id,
        text: text ?? this.text,
        title: title ?? this.title,
        at: at ?? this.at,
        ai: ai,
        nsfw: nsfw,
        ad: ad,
        keep: keep,
        spaceId: spaceId,
        boardId: boardId,
        channelId: channelId,
        bcastId: bcastId,
        repost: repost,
        poll: poll,
      );

  Map<String, dynamic> toJson() => {
    if (id.isNotEmpty) 'id': id,
    'text': text,
    'at': at,
    if (title.isNotEmpty) 'title': title,
    if (ai) 'ai': true,
    if (nsfw) 'nsfw': true,
    if (ad) 'ad': true,
    if (!keep) 'keep': false,
    'space': ?spaceId,
    'board': ?boardId,
    'channel': ?channelId,
    'bcast': ?bcastId,
    'repost': ?repost,
    'poll': ?poll?.toJson(),
  };

  static HeldPost? fromJson(Object? j) {
    if (j is! Map) return null;
    final text = j['text'];
    final at = j['at'];
    if (text is! String || at is! num) return null;
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    Map<String, dynamic>? repost;
    if (j['repost'] is Map) {
      repost = {
        for (final e in (j['repost'] as Map).entries)
          if (e.value is String) '${e.key}': e.value as String,
      };
      if (repost.isEmpty) repost = null;
    }
    return HeldPost(
      id: j['id'] is String ? j['id'] as String : '',
      text: text,
      title: j['title'] is String ? j['title'] as String : '',
      at: at.toInt(),
      ai: j['ai'] == true,
      nsfw: j['nsfw'] == true,
      ad: j['ad'] == true,
      keep: j['keep'] != false,
      spaceId: str(j['space']),
      boardId: str(j['board']),
      channelId: str(j['channel']),
      bcastId: str(j['bcast']),
      repost: repost,
      poll: Poll.fromJson(j['poll']),
    );
  }
}
