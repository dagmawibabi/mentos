import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

class PeopleScreen extends ConsumerWidget {
  const PeopleScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const <Peer>[];
    final following = people.where((x) => x.iFollow && !x.blocked).toList();
    final followers = people.where((x) => x.followsMe && !x.blocked).toList();
    final blocked = people.where((x) => x.blocked).toList();
    final all = people.where((x) => !x.blocked).toList();
    return DefaultTabController(
      length: 4,
      initialIndex: initialTab.clamp(0, 3),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('People'),
          actions: [
            IconBtn(Icons.person_add_alt_rounded, onTap: () => context.push('/connect')),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [Tab(text: 'Following'), Tab(text: 'Followers'), Tab(text: 'Everyone'), Tab(text: 'Blocked')],
          ),
        ),
        body: TabBarView(
          children: [
            _List(people: following, empty: 'You don\'t follow anyone yet'),
            _List(people: followers, empty: 'No followers yet'),
            _List(people: all, empty: 'No one here yet'),
            _List(people: blocked, empty: 'No one blocked', blockedList: true),
          ],
        ),
      ),
    );
  }
}

class _List extends ConsumerWidget {
  const _List({required this.people, required this.empty, this.blockedList = false});
  final List<Peer> people;
  final String empty;
  final bool blockedList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    if (people.isEmpty) return EmptyState(icon: Icons.people_outline_rounded, title: empty, compact: true);
    final sorted = [...people]..sort((a, b) {
        final ao = e.isOnline(a.id), bo = e.isOnline(b.id);
        if (ao != bo) return ao ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    return ListView.builder(
      itemCount: sorted.length,
      itemBuilder: (_, i) {
        final x = sorted[i];
        return ListTile(
          leading: Avatar(id: x.id, size: 42),
          title: Text(x.name),
          trailing: blockedList
              ? TextButton(onPressed: () => e.block(x.id, false), child: const Text('Unblock'))
              : x.preserve
                  ? Icon(Icons.cloud_done_outlined, size: 18, color: p.faint)
                  : null,
          onTap: () => context.push('/u/${x.id}'),
        );
      },
    );
  }
}
