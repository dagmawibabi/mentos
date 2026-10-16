import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../net/link_preview.dart';

/// A card for the first link in [text]. Uses the sender's embedded preview
/// when it matches that link, and otherwise fetches the page on this device.
class LinkCard extends StatefulWidget {
  const LinkCard({super.key, required this.text, this.attached});

  final String text;
  final LinkPreview? attached;

  @override
  State<LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<LinkCard> {
  Future<LinkPreview?>? _load;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant LinkCard old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.attached?.url != widget.attached?.url) _arm();
  }

  void _arm() {
    final url = firstHttpUrl(widget.text);
    final attached = widget.attached;
    if (url != null && attached != null && sameLink(attached.url, url)) {
      _load = null;
      return;
    }
    _load = url == null ? null : warmPreview(url);
  }

  @override
  Widget build(BuildContext context) {
    final url = firstHttpUrl(widget.text);
    if (url == null) return const SizedBox.shrink();
    final attached = widget.attached;
    if (attached != null && sameLink(attached.url, url)) {
      return _Card(preview: attached, open: url);
    }
    return FutureBuilder<LinkPreview?>(
      future: _load,
      builder: (context, snap) {
        final preview = snap.data;
        if (preview != null && preview.hasCard) return _Card(preview: preview, open: url);
        if (snap.connectionState == ConnectionState.waiting) {
          return const _Pending();
        }
        return _Bare(url: url);
      },
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending();

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text('Loading preview…', style: Txt.mono(p.faint, size: 11)),
    );
  }
}

class _Bare extends StatelessWidget {
  const _Bare({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final host = Uri.tryParse(url)?.host ?? url;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        onTap: () => _open(url),
        child: Text(host, style: Txt.mono(p.accent, size: 12)),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.preview, required this.open});
  final LinkPreview preview;
  final String open;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: p.isDark ? p.raised : p.bg,
        borderRadius: BorderRadius.circular(Radii.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(open),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview.image != null)
                Image.network(
                  preview.image!,
                  height: 132,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(preview.site, style: Txt.mono(p.faint, size: 10.5)),
                    if (preview.title.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.body(p.ink).copyWith(fontWeight: FontWeight.w600, fontSize: 14.5, height: 1.25)),
                    ],
                    if (preview.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
