import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import '../chats/chat_view.dart';

class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({super.key, required this.spaceId, required this.channelId});
  final String spaceId;
  final String channelId;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  @override
  void initState() {
    super.initState();
    ref.read(engineProvider).refreshSpace(widget.spaceId, scope: Scope.channel(widget.spaceId, widget.channelId));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final space = ref.watch(spaceProvider(widget.spaceId)).value;
    final channel = space?.channels.where((c) => c.id == widget.channelId).firstOrNull;
    final e = ref.read(engineProvider);
    final role = space?.roleOf(e.me.id) ?? Role.member;
    final name = channel?.name ?? 'channel';
    final about = (channel?.about ?? '').trim();
    final members = ref.watch(membersProvider(widget.spaceId)).value?.length ?? space?.roles.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => _info(context, name, about, members, space?.name ?? ''),
          child: Row(
            children: [
              Avatar(id: widget.spaceId, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.heading(p.ink)),
                    Text(
                      '${compact(members)} member${members == 1 ? '' : 's'}',
                      style: Txt.mono(p.muted, size: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconBtn(Icons.more_horiz_rounded, onTap: () => _info(context, name, about, members, space?.name ?? '')),
          const SizedBox(width: 4),
        ],
      ),
      body: ChatView(
        scope: Scope.channel(widget.spaceId, widget.channelId),
        group: true,
        banner: about.isEmpty ? null : _ChannelPin(text: about, onTap: () => _info(context, name, about, members, space?.name ?? '')),
        canModerate: role.index <= Role.mod.index,
        emptyTitle: 'Nothing here yet',
        emptyBody: 'Messages are encrypted with the space key and shared only with members.',
      ),
    );
  }

  void _info(BuildContext context, String name, String about, int members, String spaceName) {
    final p = context.pal;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar(id: widget.spaceId, size: 72),
              const SizedBox(height: 12),
              Text(name, style: Txt.title(p.ink)),
              Text(spaceName, style: Txt.mono(p.muted, size: 12)),
              const SizedBox(height: 12),
              if (about.isNotEmpty)
                Align(alignment: Alignment.centerLeft, child: Text(about, style: Txt.body(p.inkSoft))),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('Members', style: Txt.body(p.ink))),
                  Text(compact(members), style: Txt.mono(p.muted, size: 12)),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '$name\nspace ${widget.spaceId}'));
                    toast(ctx, 'Invite copied');
                  },
                  child: const Text('Copy invite'),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  showScopeTech(context, Scope.channel(widget.spaceId, widget.channelId), spaceId: widget.spaceId);
                },
                child: const Text('Technical details'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelPin extends StatelessWidget {
  const _ChannelPin({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Material(
      color: p.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Icon(Icons.push_pin_rounded, size: 16, color: p.accent),
              const SizedBox(width: 8),
              Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.ink))),
              Icon(Icons.chevron_right_rounded, color: p.faint),
            ],
          ),
        ),
      ),
    );
  }
}
