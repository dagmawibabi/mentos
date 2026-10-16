import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';
import '../../state/calls.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';

class TaskScreen extends ConsumerStatefulWidget {
  const TaskScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends ConsumerState<TaskScreen> {
  bool busy = false;
  final note = TextEditingController();
  final files = <Pending>[];
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> act(String action, {String? worker}) async {
    if (busy) return;
    final e = ref.read(engineProvider);
    if (action == 'accept' &&
        !await confirm(
          context,
          title: 'Accept and pay?',
          body: 'This sends the agreed Mentos to the assigned person plus a 5% network fee. Review their evidence first.',
          action: 'Accept and pay',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final media = <MediaRef>[];
      if (action == 'submit') {
        if (note.text.trim().isEmpty) {
          throw StateError('Describe how the work meets the brief');
        }
        for (final file in files) {
          media.add(await importPending(e, file));
        }
      }
      await e.taskAction(
        widget.id,
        action,
        text: note.text,
        worker: worker,
        media: media,
      );
      if (mounted) {
        note.clear();
        files.clear();
        toast(
          context,
          e.task(widget.id)?['from'] == e.me.id
              ? 'Task updated'
              : 'Sent to the task owner. Updates appear after they receive it.',
        );
      }
    } catch (err) {
      if (mounted) toast(context, '$err');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(feedProvider);
    ref.watch(coinTickProvider);
    final e = ref.watch(engineProvider);
    final row = e.task(widget.id);
    final p = context.pal;
    if (row == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Task')),
        body: const Center(
          child: Text('This task is no longer available on this device.'),
        ),
      );
    }
    final mine = row['from'] == e.me.id;
    final assigned = row['worker'] == e.me.id;
    final state = row['status'] as String? ?? 'open';
    final applications = List<String>.from(row['applications'] as List? ?? []);
    final evidence = row['evidence'] is Map ? row['evidence'] as Map : null;
    final other = mine ? row['worker'] : row['from'];
    final steps = ['open', 'in progress', 'in review', 'completed'];
    final step = state == 'changes requested' ? 1 : steps.indexOf(state);
    return Scaffold(
      appBar: AppBar(title: const Text('Task workspace')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: p.accentSoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.toUpperCase(), style: Txt.label(p.accent)),
                const SizedBox(height: 12),
                Text(
                  row['title'] as String? ?? 'Task',
                  style: Txt.display(p.ink),
                ),
                const SizedBox(height: 16),
                Text(
                  '${Coin.format(row['minor'] as int? ?? 0)} Mentos',
                  style: Txt.title(p.ink),
                ),
                Text(
                  'Paid on acceptance + 5% network fee • no escrow',
                  style: Txt.small(p.inkSoft),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (step >= 0)
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (var i = 0; i < steps.length; i++)
                  Chip(
                    avatar: Icon(
                      i <= step
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: i <= step ? p.accent : p.muted,
                    ),
                    label: Text(steps[i]),
                  ),
              ],
            ),
          const SectionLabel('The brief'),
          Text(row['about'] as String? ?? '', style: Txt.body(p.ink)),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Posted by ${e.nameOf(row['from'] as String)}'),
            subtitle: Text(
              row['worker'] == null
                  ? 'No one assigned yet'
                  : 'Assigned to ${e.nameOf(row['worker'] as String)}',
            ),
          ),
          if (other is String)
            OutlinedButton.icon(
              onPressed: () => context.push('/chat/$other'),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Discuss in chat'),
            ),
          if (mine && state == 'open') ...[
            const SectionLabel('Applications'),
            if (applications.isEmpty)
              const Text(
                'No applications yet. Your task is open to the people who receive your listing.',
              ),
            for (final applicant in applications)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.nameOf(applicant)),
                onTap: () => context.push('/chat/$applicant'),
                trailing: TextButton(
                  onPressed: busy
                      ? null
                      : () => act('assign', worker: applicant),
                  child: const Text('Assign'),
                ),
              ),
          ],
          if (evidence != null) ...[
            const SectionLabel('Submitted evidence'),
            SelectableText(evidence['text'] as String? ?? ''),
            for (final media in MediaRef.listFrom(evidence['media']))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.attach_file),
                title: Text(media.name),
                subtitle: const Text('Open evidence'),
                onTap: () async {
                  try {
                    final file = await e.media.open(
                      media,
                      sources: [
                        evidence['actor'] as String,
                        row['from'] as String,
                      ],
                    );
                    if (file == null) {
                      throw StateError(
                        'Evidence is unavailable. Its provider may be offline.',
                      );
                    }
                    await OpenFilex.open(file.path);
                  } catch (err) {
                    if (context.mounted) toast(context, '$err');
                  }
                },
              ),
          ],
          if (['changes requested', 'disputed'].contains(state)) ...[
            const SectionLabel('Requested changes'),
            Text(row['feedback'] as String? ?? ''),
          ],
          if ((assigned &&
                  ['in progress', 'changes requested'].contains(state)) ||
              (mine && ['in review', 'disputed'].contains(state))) ...[
            const SizedBox(height: 20),
            TextField(
              controller: note,
              maxLength: 2000,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: assigned
                    ? 'What you completed'
                    : 'Feedback for revisions',
                hintText: 'Describe the result and acceptance criteria.',
              ),
            ),
            if (assigned) ...[
              Text(
                'Evidence and progress are shared with this public listing. Keep private material in chat.',
                style: Txt.small(p.muted),
              ),
              for (var i = 0; i < files.length; i++)
                ListTile(
                  title: Text(files[i].name),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: busy
                        ? null
                        : () => setState(() => files.removeAt(i)),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final picked = await pickFiles(e.media, context: context);
                        if (mounted) {
                          setState(
                            () => files.addAll(picked.take(8 - files.length)),
                          );
                        }
                      },
                icon: const Icon(Icons.attach_file),
                label: const Text('Attach evidence'),
              ),
              FilledButton(
                onPressed: busy ? null : () => act('submit'),
                child: const Text('Submit for review'),
              ),
            ],
            if (mine) ...[
              if (state == 'in review')
                FilledButton(
                  onPressed: busy ? null : () => act('accept'),
                  child: const Text('Accept and pay'),
                ),
              OutlinedButton(
                onPressed: busy ? null : () => act('revise'),
                child: const Text('Request changes'),
              ),
            ],
          ],
          if (!mine && state == 'open')
            FilledButton(
              onPressed: busy
                  ? null
                  : () => act(
                      applications.contains(e.me.id) ? 'withdraw' : 'apply',
                    ),
              child: Text(
                applications.contains(e.me.id)
                    ? 'Withdraw application'
                    : 'Apply for this task',
              ),
            ),
          if (mine && state == 'open')
            TextButton(
              onPressed: busy ? null : () => act('cancel'),
              child: const Text('Cancel task'),
            ),
          if (assigned &&
              ['in progress', 'changes requested', 'disputed'].contains(state))
            TextButton(
              onPressed: busy ? null : () => act('release'),
              child: const Text('Release assignment'),
            ),
          if ((assigned || mine) &&
              ['in progress', 'in review', 'changes requested'].contains(state))
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final reason = await prompt(
                        context,
                        title: 'Raise a dispute',
                        body: 'Payment pauses. The other person sees this note, and you can keep talking in chat.',
                        hint: 'What needs resolving',
                        maxLength: 1000,
                        action: 'Raise dispute',
                        allowEmpty: false,
                      );
                      if (reason == null || !mounted) return;
                      note.text = reason;
                      await act('dispute');
                    },
              child: const Text('Raise a dispute'),
            ),
          if (state == 'disputed')
            const Text(
              'Payment is paused. Discuss the issue in chat. The owner can request revised work; the worker can release the assignment. There is no network arbitrator.',
            ),
          if (row['receipt'] is String) ...[
            const SectionLabel('Payment receipt'),
            SelectableText(row['receipt'] as String, style: Txt.mono(p.ink)),
            Text(
              e.coin?.view().contains(row['receipt'] as String) == true
                  ? 'Included in your current ledger view'
                  : 'Receipt not yet present in your ledger. Sync with peers.',
              style: Txt.small(p.muted),
            ),
          ],
          const SectionLabel('Activity'),
          for (final event in (row['timeline'] as List? ?? []).reversed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history),
              title: Text(
                '${event['action']} · ${e.nameOf(event['actor'] as String)}',
              ),
              subtitle: Text(
                '${event['text'] ?? ''}\n${DateTime.fromMillisecondsSinceEpoch(event['ts'] as int).toLocal()}',
              ),
            ),
          if (busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
