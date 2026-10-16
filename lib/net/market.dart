part of 'engine.dart';

final _taskQueues = Expando<Future<void>>();

/// Declarative packs only. Installing a pack never executes publisher code.
const starterPlugins = <Map<String, dynamic>>[
  {
    'id': 'builtin:celebrate',
    'kind': 'plugin',
    'title': 'Small celebrations',
    'about': 'A little encouragement for every finished task. Available in chat and channel sticker pickers.',
    'minor': 0,
    'from': '',
    'plugin': 'stickers',
    'body': {
      'emoji': ['🙌', '🌱', '🎉', '💪', '☕', '✨'],
    },
  },
  {
    'id': 'builtin:work',
    'kind': 'plugin',
    'title': 'Working together',
    'about': 'Useful replies for agreeing on work and sharing progress. Open Saved phrases in the composer.',
    'minor': 0,
    'from': '',
    'plugin': 'phrases',
    'body': {
      'lines': [
        'Thanks! I’ll review the details.',
        'Here is my progress so far.',
        'Could you clarify the acceptance criteria?',
        'The work is ready for review.',
      ],
    },
  },
  {
    'id': 'builtin:blue',
    'kind': 'plugin',
    'title': 'Blue hour',
    'about': 'A blue accent for your light and dark themes. Apply it after installation.',
    'minor': 0,
    'from': '',
    'plugin': 'theme',
    'body': {'accent': 'blue'},
  },
];

void validatePlugin(Map<String, dynamic> row) {
  final body = row['body'];
  if (body is! Map || jsonEncode(body).length > 8000) {
    throw ArgumentError('Invalid plugin content');
  }
  final kind = row['plugin'];
  if (kind == 'theme') {
    if (!['emerald', 'blue', 'amber', 'ink'].contains(body['accent'])) {
      throw ArgumentError('Unknown accent');
    }
  } else if (kind == 'stickers' || kind == 'phrases') {
    final values = body[kind == 'stickers' ? 'emoji' : 'lines'];
    if (values is! List ||
        values.isEmpty ||
        values.length > 24 ||
        values.any((x) => x is! String || x.trim().isEmpty || x.length > 300)) {
      throw ArgumentError('Invalid pack entries');
    }
  } else {
    throw ArgumentError('Unsupported plugin type');
  }
}

extension MarketplaceWork on Engine {
  Map<String, dynamic>? task(String id) => marketBoard()
      .where((r) => r['id'] == id && r['kind'] == 'task')
      .firstOrNull;
  List<Map<String, dynamic>> taskEvents(String id) =>
      _kvList('task-events:$id');

  Future<void> taskAction(
    String id,
    String action, {
    String text = '',
    String? worker,
    List<MediaRef> media = const [],
  }) async {
    final row = task(id);
    if (row == null || row['deleted'] == true) {
      throw StateError('Task is unavailable');
    }
    final owner = row['from'] as String;
    final event = <String, dynamic>{
      'id': '${me.id}:${toHex(randomBytes(12))}',
      'task': id,
      'action': action,
      'text': text.trim(),
      'actor': me.id,
      'ts': nowMs(),
      'worker': worker,
      'revision': row['revision'] ?? 0,
      'media': media.map((m) => m.toJson()).toList(),
    };
    if (owner == me.id) {
      await receiveTask(me.id, event);
    } else {
      if (action != 'apply' &&
          action != 'submit' &&
          action != 'withdraw' &&
          action != 'release' &&
          action != 'dispute') {
        throw StateError('Only the task owner can do that');
      }
      if (action == 'submit' && row['worker'] != me.id) {
        throw StateError('You are not assigned to this task');
      }
      await sendApp(owner, 'task', event, queueId: 'task:${event['id']}');
      _storeTaskEvent(id, {...event, 'pending': true});
    }
  }

  void _storeTaskEvent(String id, Map<String, dynamic> event) {
    final events = taskEvents(id);
    if (events.any((x) => x['id'] == event['id'])) return;
    db.setKv('task-events:$id', jsonEncode([...events, event]));
    _emit({Ch.feed});
  }

  Future<void> receiveTask(String from, Map<String, dynamic> event) {
    final next = (_taskQueues[this] ?? Future<void>.value()).then((_) => _receiveTask(from, event));
    _taskQueues[this] = next.catchError((Object _) {});
    return next;
  }

  Future<void> _receiveTask(String from, Map<String, dynamic> event) async {
    if (event['text'] is! String ||
        (event['text'] as String).length > 2000 ||
        event['ts'] is! int) {
      return;
    }
    final id = event['task'];
    if (id is! String ||
        event['id'] is! String ||
        jsonEncode(event).length > 16000) {
      return;
    }
    final row = task(id);
    if (row == null || row['from'] != me.id) return;
    if (taskEvents(id).any((x) => x['id'] == event['id'])) return;
    final action = event['action'];
    final state = row['status'] ?? 'open';
    final owner = from == me.id;
    final assigned = row['worker'] == from;
    final applications = List<String>.from(row['applications'] as List? ?? []);
    final next = Map<String, dynamic>.from(row);
    if (action == 'apply' && !owner && state == 'open') {
      if (!applications.contains(from)) applications.add(from);
      next['applications'] = applications;
    } else if (action == 'withdraw' && !owner && state == 'open') {
      applications.remove(from);
      next['applications'] = applications;
    } else if (action == 'assign' &&
        owner &&
        state == 'open' &&
        applications.contains(event['worker'])) {
      next['worker'] = event['worker'];
      next['status'] = 'in progress';
    } else if (action == 'submit' &&
        assigned &&
        ['in progress', 'changes requested'].contains(state)) {
      if ((event['text'] as String? ?? '').trim().isEmpty) {
        throw StateError('Describe the completed work');
      }
      next['status'] = 'in review';
      next['evidence'] = {
        'text': event['text'],
        'media': event['media'],
        'actor': from,
      };
    } else if (action == 'dispute' &&
        (assigned || owner) &&
        ['in progress', 'in review', 'changes requested'].contains(state)) {
      if ((event['text'] as String? ?? '').trim().isEmpty) {
        throw StateError('Describe the issue');
      }
      next['status'] = 'disputed';
      next['feedback'] = event['text'];
    } else if (action == 'revise' &&
        owner &&
        ['in review', 'disputed'].contains(state)) {
      if ((event['text'] as String? ?? '').trim().isEmpty) {
        throw StateError('Explain the requested changes');
      }
      next['status'] = 'changes requested';
      next['feedback'] = event['text'];
    } else if (action == 'cancel' && owner && state == 'open') {
      next['status'] = 'cancelled';
    } else if (action == 'release' &&
        assigned &&
        ['in progress', 'changes requested', 'disputed'].contains(state)) {
      next['status'] = 'open';
      next.remove('worker');
      applications.remove(from);
      next['applications'] = applications;
    } else if (action == 'accept' && owner && state == 'in review') {
      final receipt = await coin!.payOnce(
        row['worker'] as String,
        row['minor'] as int,
        memo: 'task:${toHex(sha256(utf8.encode(id)))}',
      );
      next['status'] = 'completed';
      next['receipt'] = receipt.hash;
    } else {
      if (owner) throw StateError('This action is no longer available');
      return;
    }
    final events = [...taskEvents(id), {...event, 'actor': from}];
    next['timeline'] = events.skip(events.length > 40 ? events.length - 40 : 0)
        .map(
          (x) => {
            'action': x['action'],
            'actor': x['actor'],
            'text': (x['text'] as String).length > 300 ? '${(x['text'] as String).substring(0, 300)}…' : x['text'],
            'ts': x['ts'],
          },
        )
        .toList();
    await postMarket(next);
    _storeTaskEvent(id, {...event, 'actor': from});
    final saved = task(id)!;
    for (final peer in {
      ...applications,
      if (row['worker'] is String) row['worker'] as String,
    }) {
      await sendApp(
        peer,
        'market',
        saved,
        queueId: 'task-update:$id:${saved['revision']}:$peer',
      );
    }
  }

  Future<void> inviteToChannel(Bcast channel, String peer) async {
    if (channel.owner != me.id) {
      throw StateError('Only the owner can invite subscribers');
    }
    final item = items(Scope.feed(me.id))
        .where((i) => i.id == channel.id)
        .firstOrNull;
    if (item == null) throw StateError('Channel is unavailable');
    await _sendOrQueue('channel-info:${channel.id}:$peer', peer, {
      't': 'item',
      'e': item.e.toWire(),
    });
    await sendApp(peer, 'channel-invite', {
      'id': channel.id,
      'name': channel.name,
    }, queueId: 'channel-invite:${channel.id}:$peer');
  }
}
