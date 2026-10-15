import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/tech.dart';
import '../../widgets/ui.dart';
import '../chats/chat_view.dart';

class ForumScreen extends ConsumerStatefulWidget {
  const ForumScreen({
    super.key,
    required this.spaceId,
    required this.boardId,
    this.legacyChannel = false,
  });
  final String spaceId;
  final String boardId;
  final bool legacyChannel;

  @override
  ConsumerState<ForumScreen> createState() => _ForumScreenState();
}

class _ForumScreenState extends ConsumerState<ForumScreen> {
  @override
  void initState() {
    super.initState();
    final scope = widget.legacyChannel
        ? Scope.channel(widget.spaceId, widget.boardId)
        : Scope.forum(widget.spaceId, widget.boardId);
    ref.read(engineProvider).refreshSpace(widget.spaceId, scope: scope);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final space = ref.watch(spaceProvider(widget.spaceId)).value;
    final board = [
      ...?space?.forums,
      ...?space?.channels,
    ].where((c) => c.id == widget.boardId).firstOrNull;
    final e = ref.read(engineProvider);
    final role = space?.roleOf(e.me.id) ?? Role.member;
    final scope = widget.legacyChannel
        ? Scope.channel(widget.spaceId, widget.boardId)
        : Scope.forum(widget.spaceId, widget.boardId);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('# ${board?.name ?? 'forum'}', style: Txt.heading(p.ink)),
            Text(space?.name ?? '', style: Txt.mono(p.muted, size: 11)),
          ],
        ),
        actions: [
          IconBtn(Icons.info_outline_rounded,
              tooltip: 'Technical', onTap: () => showScopeTech(context, scope, spaceId: widget.spaceId)),
        ],
      ),
      body: ChatView(
        scope: scope,
        group: true,
        canModerate: role.index <= Role.mod.index,
        emptyTitle: 'Nothing here yet',
        emptyBody: 'Forum rooms are encrypted with the space key. Same as the old channels, now with a clearer name.',
      ),
    );
  }
}
