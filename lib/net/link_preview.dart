import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The first http(s) URL in [text], with trailing punctuation removed.
String? firstHttpUrl(String text) {
  final m = RegExp(r'https?://[^\s<>"\]]+', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  var url = m.group(0)!;
  while (url.isNotEmpty && '.,);:]'.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  return uri.toString();
}

bool sameLink(String a, String b) {
  final ua = Uri.tryParse(a);
  final ub = Uri.tryParse(b);
  if (ua == null || ub == null) return a == b;
  String path(Uri u) => u.path.isEmpty ? '/' : u.path;
  return ua.scheme.toLowerCase() == ub.scheme.toLowerCase() &&
      ua.host.toLowerCase() == ub.host.toLowerCase() &&
      ua.hasPort == ub.hasPort &&
      ua.port == ub.port &&
      path(ua) == path(ub) &&
      ua.query == ub.query;
}

/// True for a normal public web address. Private, loopback and local names
/// are refused so a preview fetch cannot probe the device's own network.
bool isPublicHttpUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  final host = uri.host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return false;
  final ip = InternetAddress.tryParse(host);
  if (ip != null && !isPublicAddress(ip)) return false;
  return true;
}

bool isPublicAddress(InternetAddress ip) {
  if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return false;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4 && b.length == 4) {
    final a = b[0];
    final c = b[1];
    if (a == 0 || a == 10 || a == 127) return false;
    if (a == 169 && c == 254) return false;
    if (a == 172 && c >= 16 && c <= 31) return false;
    if (a == 192 && c == 168) return false;
    if (a == 100 && c >= 64 && c <= 127) return false;
    return true;
  }
  if (ip.type == InternetAddressType.IPv6 && b.isNotEmpty) {
    if ((b[0] & 0xfe) == 0xfc) return false;
    return true;
  }
  return false;
}

class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.title,
    required this.description,
    required this.site,
    this.image,
  });

  final String url;
  final String title;
  final String description;
  final String site;
  final String? image;

  bool get hasCard => title.isNotEmpty || description.isNotEmpty || image != null;

  Map<String, dynamic> toJson() => {
        'u': url,
        'ti': title,
        'd': description,
        'h': site,
        if (image != null) 'im': image,
      };

  static LinkPreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['u'];
    if (url is! String || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !isPublicHttpUrl(uri)) return null;
    final image = raw['im'];
    final imageUri = image is String ? Uri.tryParse(image) : null;
    return LinkPreview(
      url: url,
      title: _clip(raw['ti'], 140),
      description: _clip(raw['d'], 240),
      site: _clip(raw['h'], 80).isEmpty ? uri.host : _clip(raw['h'], 80),
      image: imageUri != null && isPublicHttpUrl(imageUri) ? imageUri.toString() : null,
    );
  }
}

String _clip(Object? v, int max) {
  if (v is! String) return '';
  final t = v.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= max ? t : t.substring(0, max);
}

final _mem = <String, LinkPreview>{};
final _pending = <String, Future<LinkPreview?>>{};

/// A preview already fetched during this run, if the text contains its URL.
LinkPreview? cachedPreview(String text) {
  final url = firstHttpUrl(text);
  if (url == null) return null;
  return _mem[url];
}

/// Preview to embed in a message. Returns immediately when one is already
/// cached, and otherwise waits briefly so a fast send still carries a card.
Future<Map<String, dynamic>?> previewBody(String text) async {
  if (firstHttpUrl(text) == null) return null;
  final ready = cachedPreview(text) ??
      await warmPreview(text).timeout(const Duration(milliseconds: 1500), onTimeout: () => cachedPreview(text));
  return ready?.toJson();
}

/// Fetches [text]'s first link once and remembers it. Null when there is no
/// public link, or the page could not be read.
Future<LinkPreview?> warmPreview(String text) {
  final url = firstHttpUrl(text);
  if (url == null) return Future.value();
  final hit = _mem[url];
  if (hit != null) return Future.value(hit);
  return _pending[url] ??= _load(url);
}

Future<LinkPreview?> _load(String url) async {
  try {
    final preview = await fetchLinkPreview(url);
    if (preview != null) _mem[url] = preview;
    return preview;
  } finally {
    _pending.remove(url);
  }
}

/// Reads Open Graph (and a few fallbacks) from [url]. [allow] overrides the
/// public-address check, used by tests against a local server.
Future<LinkPreview?> fetchLinkPreview(
  String url, {
  bool Function(Uri uri)? allow,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final ok = allow ?? isPublicHttpUrl;
  if (!ok(uri)) return null;
  if (allow == null && !await _hostIsPublic(uri.host)) return null;
  final client = HttpClient();
  client.connectionTimeout = timeout;
  client.userAgent = 'Mentos/1.0';
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.followRedirects = true;
    req.maxRedirects = 3;
    req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
    final res = await req.close().timeout(timeout);
    final settled = res.redirects.isEmpty ? uri : res.redirects.last.location;
    if (!ok(settled)) return null;
    if (res.statusCode >= 400) return null;
    final type = res.headers.contentType?.mimeType ?? '';
    if (type.isNotEmpty && !type.contains('html') && !type.contains('xml') && type != 'text/plain') {
      return LinkPreview(url: settled.toString(), title: '', description: '', site: settled.host);
    }
    final bytes = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > 256 * 1024) break;
    }
    final html = utf8.decode(bytes, allowMalformed: true);
    return parseLinkPreview(html, settled);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _hostIsPublic(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return isPublicAddress(literal);
  try {
    final found = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
    return found.isNotEmpty && found.every(isPublicAddress);
  } catch (_) {
    return false;
  }
}

/// Pulls title, description and image out of an HTML document.
LinkPreview parseLinkPreview(String html, Uri page) {
  final tags = <String, String>{};
  for (final m in _meta.allMatches(html)) {
    tags.putIfAbsent(m.group(1)!.toLowerCase(), () => _decode(m.group(2)!));
  }
  for (final m in _metaRev.allMatches(html)) {
    tags.putIfAbsent(m.group(2)!.toLowerCase(), () => _decode(m.group(1)!));
  }
  final title = _first(tags, const ['og:title', 'twitter:title']) ?? _title(html) ?? '';
  final description = _first(tags, const ['og:description', 'twitter:description', 'description']) ?? '';
  final imageRaw = _first(tags, const ['og:image', 'twitter:image']);
  String? image;
  if (imageRaw != null && imageRaw.isNotEmpty) {
    final resolved = page.resolve(imageRaw);
    if (isPublicHttpUrl(resolved)) image = resolved.toString();
  }
  return LinkPreview(
    url: page.toString(),
    title: _clip(title, 140),
    description: _clip(description, 240),
    site: page.host,
    image: image,
  );
}

String? _first(Map<String, String> tags, List<String> keys) {
  for (final k in keys) {
    final v = tags[k];
    if (v != null && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

String? _title(String html) {
  final m = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html);
  if (m == null) return null;
  final t = _decode(m.group(1)!).trim();
  return t.isEmpty ? null : t;
}

final _meta = RegExp(
  '''<meta\\s+[^>]*?(?:property|name)\\s*=\\s*["']([^"']+)["'][^>]*?content\\s*=\\s*["']([^"']*)["'][^>]*>''',
  caseSensitive: false,
);

final _metaRev = RegExp(
  '''<meta\\s+[^>]*?content\\s*=\\s*["']([^"']*)["'][^>]*?(?:property|name)\\s*=\\s*["']([^"']+)["'][^>]*>''',
  caseSensitive: false,
);

String _decode(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final n = int.tryParse(m.group(1)!);
      return n == null ? m.group(0)! : String.fromCharCode(n);
    });
