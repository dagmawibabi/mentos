import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/call/calls.dart';
import '../../net/call/live.dart';
import '../../net/pay/coin.dart';
import '../../widgets/ui.dart';

/// How the network, storage, and cryptography actually work.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _Topic {
  _Topic({
    required this.id,
    required this.chip,
    required this.title,
    required this.paragraphs,
    this.facts = const [],
  });

  final String id;
  final String chip;
  final String title;
  final List<String> paragraphs;
  final List<(String, String)> facts;
  final key = GlobalKey();
}

class _HelpScreenState extends State<HelpScreen> {
  final _scroll = ScrollController();
  late final List<_Topic> _topics = _buildTopics();
  String _current = 'path';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_track);
  }

  @override
  void dispose() {
    _scroll.removeListener(_track);
    _scroll.dispose();
    super.dispose();
  }

  List<_Topic> _buildTopics() {
    final grant = Coin.format(Coin.grant);
    final badge = Coin.format(Coin.badgeBase);
    return [
      _Topic(
        id: 'path',
        chip: 'Path',
        title: 'How something reaches someone',
        paragraphs: [
          'There is no account server and no inbox waiting in a data center. A post, message, or payment is signed on this phone and handed to another phone that is online at the same time.',
          'The connection is iroh: QUIC, with a direct path punched through the routers when that works, and an encrypted relay when it does not. Relays move ciphertext. They do not store posts, chats, or the ledger, and they cannot read them.',
          'You meet someone with a ticket or a QR code, or because your phones already share a feed, a space, a group, or the coin ledger. Public spaces and marketplace listings are signed by their owners and spread from phone to phone, so they also reach people who have never met.',
        ],
      ),
      _Topic(
        id: 'key',
        chip: 'Key',
        title: 'Your key is the account',
        paragraphs: [
          'The account is an Ed25519 key. The public half is your id, 64 hexadecimal characters, and it is also your address on the network. A message addressed to you can only be accepted by a phone holding the matching private half.',
          'The recovery phrase is 24 words that are the key itself, not a password for a website. Restoring the phrase is the same account. Anyone who has the phrase is you. Without it, erasing this phone erases the key. Copies other people were allowed to keep stay with them. Those copies are not a backup of the private key.',
          'The database on this phone is encrypted with a separate key. An app PIN, if you set one, is stored as a slow hash of the digits, not as the digits.',
        ],
      ),
      _Topic(
        id: 'crypto',
        chip: 'Crypto',
        title: 'What is signed, sealed, and encrypted',
        paragraphs: [
          'Every post, message, profile, and payment is one fixed text plus an Ed25519 signature over those exact bytes. Changing a word after signing makes the check fail, and other phones drop it. Data explorer can run that check on what this phone is holding.',
          'The connection itself is encrypted, so a relay sees ciphertext. That is not the same as hiding a public post. Public posts are signed and readable by phones that receive them. Direct messages go only to that person, on a connection authenticated as their key.',
          'Groups and spaces add a second lock. Their contents are sealed with XChaCha20-Poly1305 under a key shared by the members. A group key is handed over only after an invite is accepted, and it changes when someone leaves, so they cannot read what is said next.',
          'A file uses its own AES-256-GCM key. The bytes on disk and on the wire are ciphertext. The key travels inside the signed message that offers the file. A download is checked against the SHA-256 of those bytes before it is kept.',
        ],
        facts: const [
          ('Identity', 'Ed25519. The public key is the id and the network address.'),
          ('Link', 'iroh QUIC. Encrypted end to end, direct or through a relay.'),
          ('Groups, spaces', 'XChaCha20-Poly1305. A shared key on top of the link.'),
          ('Files', 'AES-256-GCM per file. SHA-256 checked on download.'),
          ('This phone', 'Encrypted database. PIN stored as a slow hash.'),
        ],
      ),
      _Topic(
        id: 'where',
        chip: 'Where',
        title: 'Yours, kept, and live',
        paragraphs: [
          'Yours: you created it. It sits in the encrypted database, and this phone can serve it.',
          'Kept: someone else created it, they allowed a copy, and this phone accepted. It stays when they go offline, and this phone can serve it for them. Settings decides whether followers may keep your posts, whether authors may keep your replies, and whether contacts may remember your profile. Turning one off asks them to delete their copies.',
          'Live: you are seeing it because a source is reachable right now. It is not written down. When that source leaves, it leaves too.',
        ],
      ),
      _Topic(
        id: 'chats',
        chip: 'Chats',
        title: 'Messages',
        paragraphs: [
          'A chat message is saved here, then sent straight to each recipient. Sent means the bytes left this phone. Delivered means their app accepted that exact message. Read means they sent a receipt, and only if receipts are on for both of you.',
          'A gossip broadcast is not delivery. A group message becomes delivered when each tracked recipient has confirmed it. If someone is offline, the message waits here and is retried. It arrives when both phones are reachable, or when a phone that was allowed to keep the conversation is.',
          'Blocked people are ignored. Cancelling a retry stops further attempts from here. It cannot delete a copy someone already accepted.',
        ],
      ),
      _Topic(
        id: 'social',
        chip: 'Social',
        title: 'Posts, stories, spaces, channels',
        paragraphs: [
          'Your feed is what this phone publishes. With discovery on, phones you have not followed can see the profile and public posts when the nodes meet. With it off, those go only to people you already know. There is no global search.',
          'Stories expire. A reply to a story lands in your chats. Comments, likes, and votes point at a post and are signed by the person who left them.',
          'A space has channels and a forum, sealed for its members. A channel you own is a broadcast: people subscribe with their own signature, and an invite waits until they accept. Comments can be turned off. A modified app could still send one; it is not shown.',
        ],
      ),
      _Topic(
        id: 'files',
        chip: 'Files',
        title: 'Files this phone hosts',
        paragraphs: [
          'A file stays on the phone that hosts it and is fetched by its hash. You choose what to host, and a storage limit caps how much. Downloads can start on their own from people you follow, up to a size you set.',
          'Pause that survives a restart is not available yet. The transfer has to be running while both phones are reachable.',
        ],
      ),
      _Topic(
        id: 'calls',
        chip: 'Calls',
        title: 'Calls and live',
        paragraphs: [
          'A call is arranged over the direct link. Voice and video then move as packets that are not resent if they arrive late. A late frame is dropped. Only people invited to that call can send into it. The packets are still encrypted.',
          'A group call is a full mesh of up to ${CallManager.maxMembers} phones. Live is the channel owner serving up to ${LiveManager.maxViewers} viewers from their own phone. Sound is 16 kHz PCM. Picture is a small JPEG.',
        ],
      ),
      _Topic(
        id: 'privacy',
        chip: 'Privacy',
        title: 'Who can see your IP',
        paragraphs: [
          'Encryption stays on in every mode. The mode is chosen before the node binds, and changing it restarts the node.',
          'Standard tries a direct path. The person you connect to can learn your IP. Hide my IP opens no direct sockets, so peers only see the relay, and the relay sees your IP plus ciphertext. Tor is hide-my-IP through a local HTTP proxy such as Orbot, so the relay sees a Tor exit instead of this phone. It is the slowest.',
        ],
      ),
      _Topic(
        id: 'coins',
        chip: 'Coins',
        title: 'The Mentos ledger',
        paragraphs: [
          'Mentos coins are one ledger the phones keep together, not a bank balance. The treasury starts holding the entire supply and has no private key, so it cannot spend on its own. Nothing else mints coins. A new identity may draw $grant once, signed by its own key. Restoring the phrase writes that same draw again, not a second one.',
          'Later payments are signed by the sender and name the hash of their previous payment. Phones that have seen the same payments compute the same balances. Every phone signs a vote for the first payment it sees at each place in a chain; if someone signs two payments that spend the same coins, the one backed by more witness stake is kept and the account is flagged as a double spender.',
          'Escrow is part of the ledger. A hold moves coins out of the payer’s balance for a payee. Only the payer can release it; the payee can hand it back; once the payee has accepted and the deadline passes without a dispute, the payee can claim it. An arbiter both sides agreed on can split a disputed hold. Marketplace orders, tasks, rentals and birr trades all pay this way.',
          'A checkmark pays the treasury. The price starts at $badge while the treasury is full and moves as coins are drawn out and paid back. A service payment adds a fee of one part in twenty, which the treasury receives. The other person receives the amount you agreed.',
          'Two groups of phones that have not met can disagree until they exchange what they have seen. This is not irreversible settlement. A birr price on a listing is an agreement between two people. The app moves Mentos, not bank money.',
        ],
      ),
      _Topic(
        id: 'limits',
        chip: 'Limits',
        title: 'What this will not do',
        paragraphs: [
          'It will not deliver a message to a phone that is never online at the same time as a phone holding that message. There is no store-and-forward server.',
          'It will not restore the key if the phrase is gone. It will not stop a modified app from hiding something it received. It will stop that app from forging your signature.',
          'It will not promise two phones agree on a coin balance before they have exchanged the ledger. It will not keep running in the background unless you turn that on, and the phone can still stop it.',
        ],
      ),
    ];
  }

  void _track() {
    if (!mounted) return;
    var next = _topics.first.id;
    for (final topic in _topics) {
      final box = topic.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.localToGlobal(Offset.zero).dy < 140) next = topic.id;
    }
    if (next != _current) setState(() => _current = next);
  }

  void _jump(_Topic topic) {
    setState(() => _current = topic.id);
    final target = topic.key.currentContext;
    if (target == null) return;
    final reduce = MediaQuery.disableAnimationsOf(context);
    Scrollable.ensureVisible(
      target,
      alignment: 0.02,
      duration: reduce ? Duration.zero : Motion.base,
      curve: Motion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: Space.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your phone is the account.', style: Txt.display(p.ink)),
                const SizedBox(height: Space.md),
                Text(
                  'Posts, chats, files, calls, and coins live on the device that made them. Other people see them while a phone holding a copy is reachable.',
                  style: Txt.body(p.inkSoft),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _State(kind: Provenance.mine, text: 'Created here. This phone stores it and can serve it.'),
                const SizedBox(width: Space.sm),
                _State(kind: Provenance.kept, text: 'Someone allowed a copy, and this phone accepted.'),
                const SizedBox(width: Space.sm),
                _State(kind: Provenance.live, text: 'Visible only while a source is online. Not saved.'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, Space.sm),
            child: Wrap(
              children: [
                for (final topic in _topics) _chip(p, topic),
              ],
            ),
          ),
          for (final topic in _topics) _section(p, topic),
          const SectionLabel('On this phone'),
          RowTile(
            icon: Icons.shield_outlined,
            title: 'Privacy and transports',
            subtitle: 'Standard, hide my IP, or Tor',
            onTap: () => context.push('/privacy'),
          ),
          RowTile(
            icon: Icons.monitor_heart_outlined,
            title: 'Network diagnostics',
            subtitle: 'What this node can actually measure',
            onTap: () => context.push('/diagnostics'),
          ),
          RowTile(
            icon: Icons.data_object_rounded,
            title: 'Data explorer',
            subtitle: 'Verify signatures and export what is stored here',
            onTap: () => context.push('/data'),
          ),
          RowTile(
            icon: Icons.key_rounded,
            title: 'Recovery phrase',
            subtitle: 'The 24 words that are this key',
            onTap: () => context.push('/backup'),
          ),
          RowTile(
            icon: Icons.hub_outlined,
            title: 'Network',
            subtitle: 'Who is reachable, and who is keeping copies',
            onTap: () => context.go('/network'),
          ),
          RowTile(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Wallet',
            subtitle: 'Balances from the payments this phone has seen',
            onTap: () => context.go('/wallet'),
          ),
          const SizedBox(height: Space.xl),
          Center(
            child: TextButton(
              onPressed: () => launchUrl(Uri.parse('https://iroh.computer'), mode: LaunchMode.externalApplication),
              child: Text('iroh.computer', style: Txt.mono(p.ink, size: 12, w: FontWeight.w500)),
            ),
          ),
          Center(child: Text('The network under the direct path and the relays.', style: Txt.small(p.faint))),
          const SizedBox(height: Space.sm),
          Center(
            child: TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://github.com/dagmawibabi/mentos'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text('github.com/dagmawibabi/mentos', style: Txt.mono(p.ink, size: 12, w: FontWeight.w500)),
            ),
          ),
          Center(child: Text('Source code for this app.', style: Txt.small(p.faint))),
          ],
        ),
      ),
    );
  }

  Widget _chip(Palette p, _Topic topic) {
    final on = topic.id == _current;
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: Material(
        color: on ? p.ink : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: on ? p.ink : p.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _jump(topic),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(topic.chip, style: Txt.mono(on ? p.bg : p.inkSoft, size: 12, w: FontWeight.w500)),
          ),
        ),
      ),
    );
  }

  Widget _section(Palette p, _Topic topic) {
    return Padding(
      key: topic.key,
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(topic.chip.toUpperCase(), style: Txt.label(p.muted)),
            const SizedBox(height: Space.xs),
            Text(topic.title, style: Txt.heading(p.ink)),
            for (final paragraph in topic.paragraphs) ...[
              const SizedBox(height: Space.sm),
              Text(paragraph, style: Txt.body(p.inkSoft)),
            ],
            if (topic.facts.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              for (final fact in topic.facts) _fact(p, fact.$1, fact.$2),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fact(Palette p, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Txt.mono(p.muted, size: 11, w: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value, style: Txt.small(p.ink)),
        ],
      ),
    );
  }
}

class _State extends StatelessWidget {
  const _State({required this.kind, required this.text});
  final Provenance kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final live = kind == Provenance.live;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(Space.sm),
        decoration: BoxDecoration(
          color: live ? p.accentSoft : p.surface,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: live ? p.accentSoft : p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProvenanceTag(kind),
            const SizedBox(height: Space.sm),
            Text(text, style: Txt.small(live ? p.inkSoft : p.muted)),
          ],
        ),
      ),
    );
  }
}
