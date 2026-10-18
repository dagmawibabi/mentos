import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/db.dart';

/// The two OpenAI-compatible gateways a person can bring a key for.
enum AiGateway {
  openrouter('OpenRouter', 'https://openrouter.ai/api/v1/chat/completions', 'https://openrouter.ai/keys', 'sk-or-'),
  vercel('Vercel AI Gateway', 'https://ai-gateway.vercel.sh/v1/chat/completions', 'https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys', 'vck_');

  const AiGateway(this.label, this.endpoint, this.keysPage, this.keyPrefix);
  final String label;
  final String endpoint;
  final String keysPage;
  final String keyPrefix;

  /// The provider's section in models.dev.
  String get catalogId => name;

  /// What "Auto" sends.
  String get autoModel => this == AiGateway.openrouter ? 'openrouter/auto' : 'openai/gpt-4o-mini';
}

/// One model from models.dev.
class AiModel {
  const AiModel({
    required this.id,
    required this.name,
    this.description = '',
    this.reasoning = false,
    this.tools = false,
    this.attachment = false,
    this.input = const ['text'],
    this.context = 0,
    this.output = 0,
    this.costIn,
    this.costOut,
    this.knowledge,
    this.released,
    this.updated,
    this.openWeights = false,
  });

  final String id;
  final String name;
  final String description;
  final bool reasoning;
  final bool tools;
  final bool attachment;
  final List<String> input;
  final int context;
  final int output;

  /// USD per million tokens.
  final double? costIn;
  final double? costOut;
  final String? knowledge;
  final String? released;
  final String? updated;
  final bool openWeights;

  bool get images => input.contains('image');
  bool get pdfs => input.contains('pdf') || attachment;

  /// The lab before the slash, e.g. "anthropic".
  String get vendor => id.contains('/') ? id.split('/').first : 'other';
  String get lab => labName(vendor);

  static const _labs = {
    'openai': 'OpenAI', 'anthropic': 'Anthropic', 'google': 'Google', 'meta-llama': 'Meta', 'meta': 'Meta',
    'mistralai': 'Mistral', 'mistral': 'Mistral', 'x-ai': 'xAI', 'xai': 'xAI', 'deepseek': 'DeepSeek',
    'qwen': 'Alibaba', 'alibaba': 'Alibaba', 'amazon': 'Amazon', 'cohere': 'Cohere', 'moonshotai': 'Moonshot AI',
    'z-ai': 'Z.ai', 'zai': 'Z.ai', 'microsoft': 'Microsoft', 'nvidia': 'NVIDIA', 'perplexity': 'Perplexity',
    'minimax': 'MiniMax', 'baidu': 'Baidu', 'bytedance': 'ByteDance', 'inception': 'Inception', 'openrouter': 'OpenRouter',
    'nousresearch': 'Nous Research', 'ai21': 'AI21', 'inflection': 'Inflection', 'liquid': 'Liquid', 'tencent': 'Tencent',
  };

  static String labName(String vendor) {
    final known = _labs[vendor];
    if (known != null) return known;
    return vendor.split(RegExp(r'[-_]')).map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
  }

  Map<String, Object?> toJson() => {
    'id': id, 'name': name, 'd': description, 'r': reasoning, 't': tools, 'a': attachment, 'in': input,
    'ctx': context, 'out': output, 'ci': costIn, 'co': costOut, 'k': knowledge, 'rel': released, 'upd': updated, 'ow': openWeights,
  };

  static AiModel fromJson(Map j) => AiModel(
    id: j['id'] as String,
    name: j['name'] as String,
    description: (j['d'] as String?) ?? '',
    reasoning: j['r'] == true,
    tools: j['t'] == true,
    attachment: j['a'] == true,
    input: [for (final x in (j['in'] as List?) ?? const ['text']) '$x'],
    context: (j['ctx'] as num?)?.toInt() ?? 0,
    output: (j['out'] as num?)?.toInt() ?? 0,
    costIn: (j['ci'] as num?)?.toDouble(),
    costOut: (j['co'] as num?)?.toDouble(),
    knowledge: j['k'] as String?,
    released: j['rel'] as String?,
    updated: j['upd'] as String?,
    openWeights: j['ow'] == true,
  );

  /// Reads one provider's chat models out of the full models.dev file.
  static List<AiModel> fromCatalog(Map<String, dynamic> provider) {
    final out = <AiModel>[];
    final models = provider['models'];
    if (models is! Map) return out;
    for (final raw in models.values) {
      if (raw is! Map) continue;
      final id = raw['id'];
      final name = raw['name'];
      if (id is! String || name is! String) continue;
      if (RegExp(r'rerank|embed|whisper|tts|moderation|image-gen|dall-e', caseSensitive: false).hasMatch(id)) continue;
      final mod = raw['modalities'];
      final outputs = mod is Map && mod['output'] is List ? (mod['output'] as List).map((e) => '$e').toList() : const ['text'];
      if (!outputs.contains('text')) continue;
      final inputs = mod is Map && mod['input'] is List ? (mod['input'] as List).map((e) => '$e').toList() : const ['text'];
      final limit = raw['limit'] is Map ? raw['limit'] as Map : const {};
      final cost = raw['cost'] is Map ? raw['cost'] as Map : const {};
      out.add(AiModel(
        id: id,
        name: name,
        description: raw['description'] is String ? raw['description'] as String : '',
        reasoning: raw['reasoning'] == true,
        tools: raw['tool_call'] == true,
        attachment: raw['attachment'] == true,
        input: inputs,
        context: (limit['context'] as num?)?.toInt() ?? 0,
        output: (limit['output'] as num?)?.toInt() ?? 0,
        costIn: (cost['input'] as num?)?.toDouble(),
        costOut: (cost['output'] as num?)?.toDouble(),
        knowledge: raw['knowledge'] as String?,
        released: raw['release_date'] as String?,
        updated: raw['last_updated'] as String?,
        openWeights: raw['open_weights'] == true,
      ));
    }
    out.sort((a, b) {
      final l = a.lab.compareTo(b.lab);
      if (l != 0) return l;
      return (b.released ?? '').compareTo(a.released ?? '');
    });
    return out;
  }
}

/// A file attached to a message, copied into the app's AI folder.
class AiAttachment {
  const AiAttachment({required this.path, required this.name, required this.mime, required this.size});
  final String path;
  final String name;
  final String mime;
  final int size;

  bool get isImage => mime.startsWith('image/');
  bool get isPdf => mime == 'application/pdf';
  bool get isText =>
      mime.startsWith('text/') ||
      const ['application/json', 'application/xml', 'application/javascript', 'application/x-yaml'].contains(mime);

  Map<String, Object> toJson() => {'path': path, 'name': name, 'mime': mime, 'size': size};
  static AiAttachment fromJson(Map j) =>
      AiAttachment(path: j['path'] as String, name: j['name'] as String, mime: j['mime'] as String, size: (j['size'] as num).toInt());

  static String mimeOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'pdf' => 'application/pdf',
      'json' => 'application/json',
      'xml' => 'application/xml',
      'js' || 'mjs' => 'application/javascript',
      'yaml' || 'yml' => 'application/x-yaml',
      'md' || 'markdown' => 'text/markdown',
      'csv' => 'text/csv',
      'html' || 'htm' => 'text/html',
      'txt' || 'log' || 'dart' || 'py' || 'ts' || 'tsx' || 'jsx' || 'java' || 'kt' || 'swift' || 'go' || 'rs' || 'c' || 'cpp' || 'h' ||
      'cs' || 'rb' || 'php' || 'sh' || 'sql' || 'toml' || 'ini' || 'css' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }
}

class AiMessage {
  AiMessage({required this.role, required this.text, this.attachments = const [], this.model, this.reasoning = '', this.error, int? ts})
      : ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  final String role; // user | assistant
  String text;
  String reasoning;
  final List<AiAttachment> attachments;
  String? model;
  String? error;
  final int ts;

  Map<String, Object?> toJson() => {
    'role': role,
    'text': text,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (attachments.isNotEmpty) 'files': [for (final a in attachments) a.toJson()],
    'model': ?model,
    'error': ?error,
    'ts': ts,
  };

  static AiMessage fromJson(Map j) => AiMessage(
    role: j['role'] as String,
    text: (j['text'] as String?) ?? '',
    reasoning: (j['reasoning'] as String?) ?? '',
    attachments: [for (final f in (j['files'] as List?) ?? const []) AiAttachment.fromJson(f as Map)],
    model: j['model'] as String?,
    error: j['error'] as String?,
    ts: (j['ts'] as num?)?.toInt(),
  );
}

class AiConversation {
  AiConversation({required this.id, this.title = '', List<AiMessage>? messages, int? updated})
      : messages = messages ?? [],
        updated = updated ?? DateTime.now().millisecondsSinceEpoch;
  final String id;
  String title;
  final List<AiMessage> messages;
  int updated;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'updated': updated, 'messages': [for (final m in messages) m.toJson()]};
  static AiConversation fromJson(Map j) => AiConversation(
    id: j['id'] as String,
    title: (j['title'] as String?) ?? '',
    updated: (j['updated'] as num?)?.toInt(),
    messages: [for (final m in (j['messages'] as List?) ?? const []) AiMessage.fromJson(m as Map)],
  );
}

/// One streamed chunk: answer text, reasoning text, or the final usage.
class AiDelta {
  const AiDelta({this.text = '', this.reasoning = '', this.model});
  final String text;
  final String reasoning;
  final String? model;
}

class AiError implements Exception {
  AiError(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// Settings, keys and chats, kept in the identity's encrypted database.
class AiStore extends ChangeNotifier {
  AiStore(this.db);
  final Db db;

  AiGateway get gateway => AiGateway.values.firstWhere((g) => g.name == db.getKv('ai:gw'), orElse: () => AiGateway.openrouter);
  set gateway(AiGateway g) {
    db.setKv('ai:gw', g.name);
    notifyListeners();
  }

  String keyFor(AiGateway g) => db.getKv('ai:key:${g.name}') ?? '';
  void setKey(AiGateway g, String key) {
    if (key.trim().isEmpty) {
      db.deleteKv('ai:key:${g.name}');
    } else {
      db.setKv('ai:key:${g.name}', key.trim());
    }
    notifyListeners();
  }

  bool get ready => keyFor(gateway).isNotEmpty;

  /// Null means Auto.
  String? get model {
    final m = db.getKv('ai:model:${gateway.name}');
    return m == null || m.isEmpty ? null : m;
  }

  set model(String? id) {
    if (id == null) {
      db.deleteKv('ai:model:${gateway.name}');
    } else {
      db.setKv('ai:model:${gateway.name}', id);
    }
    notifyListeners();
  }

  String get systemPrompt => db.getKv('ai:system') ?? '';
  set systemPrompt(String v) {
    db.setKv('ai:system', v.trim());
    notifyListeners();
  }

  // ------------------------------------------------------------ chats

  List<AiConversation> conversations() {
    final out = <AiConversation>[];
    for (final k in db.kvKeys('ai:conv:')) {
      try {
        out.add(AiConversation.fromJson(jsonDecode(db.getKv(k)!) as Map));
      } catch (_) {}
    }
    return out..sort((a, b) => b.updated.compareTo(a.updated));
  }

  AiConversation? conversation(String id) {
    final raw = db.getKv('ai:conv:$id');
    if (raw == null) return null;
    try {
      return AiConversation.fromJson(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  void save(AiConversation c) {
    if (c.messages.isEmpty) return;
    c.updated = DateTime.now().millisecondsSinceEpoch;
    if (c.title.isEmpty) {
      final first = c.messages.firstWhere((m) => m.role == 'user', orElse: () => c.messages.first).text.trim();
      c.title = first.isEmpty ? 'New chat' : (first.length > 60 ? '${first.substring(0, 60)}…' : first);
    }
    db.setKv('ai:conv:${c.id}', jsonEncode(c.toJson()));
    db.setKv('ai:last', c.id);
    notifyListeners();
  }

  void delete(String id) {
    final c = conversation(id);
    for (final m in c?.messages ?? const <AiMessage>[]) {
      for (final a in m.attachments) {
        try {
          File(a.path).deleteSync();
        } catch (_) {}
      }
    }
    db.deleteKv('ai:conv:$id');
    notifyListeners();
  }

  String? get lastConversation => db.getKv('ai:last');

  // ------------------------------------------------------------ models

  List<AiModel> cachedModels(AiGateway g) {
    try {
      final raw = db.getKv('ai:models:${g.name}');
      if (raw == null) return const [];
      return [for (final m in (jsonDecode(raw)['list'] as List)) AiModel.fromJson(m as Map)];
    } catch (_) {
      return const [];
    }
  }

  int modelsFetchedAt(AiGateway g) {
    try {
      return ((jsonDecode(db.getKv('ai:models:${g.name}') ?? '{}') as Map)['ts'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Fresh model list from models.dev, cached for a day.
  Future<List<AiModel>> models(AiGateway g, {bool force = false, Future<String> Function(Uri)? fetch}) async {
    final cached = cachedModels(g);
    final age = DateTime.now().millisecondsSinceEpoch - modelsFetchedAt(g);
    if (!force && cached.isNotEmpty && age < const Duration(days: 1).inMilliseconds) return cached;
    try {
      final raw = await (fetch ?? _get)(Uri.parse('https://models.dev/api.json'));
      final list = await compute(_extract, (raw, g.catalogId));
      if (list.isNotEmpty) {
        db.setKv('ai:models:${g.name}', jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch, 'list': list}));
        notifyListeners();
        return [for (final m in list) AiModel.fromJson(m)];
      }
    } catch (_) {
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
    return cached;
  }

  AiModel? find(String? id) {
    if (id == null) return null;
    for (final m in cachedModels(gateway)) {
      if (m.id == id) return m;
    }
    return null;
  }
}

List<Map<String, Object?>> _extract((String, String) args) {
  final all = jsonDecode(args.$1) as Map<String, dynamic>;
  final provider = all[args.$2];
  if (provider is! Map<String, dynamic>) return const [];
  return [for (final m in AiModel.fromCatalog(provider)) m.toJson()];
}

Future<String> _get(Uri u) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(u);
    final res = await req.close().timeout(const Duration(seconds: 90));
    if (res.statusCode != 200) throw AiError('models.dev answered ${res.statusCode}');
    return await utf8.decodeStream(res);
  } finally {
    client.close();
  }
}

/// Streams a chat completion from an OpenAI-compatible gateway.
class AiClient {
  AiClient({required this.gateway, required this.apiKey, this.endpoint});
  final AiGateway gateway;
  final String apiKey;

  /// Overrides the gateway URL, for tests.
  final Uri? endpoint;
  HttpClient? _http;

  void cancel() {
    _http?.close(force: true);
    _http = null;
  }

  /// Builds the OpenAI message list, turning attachments into content parts.
  static Future<List<Map<String, Object?>>> buildMessages(List<AiMessage> history, {String system = ''}) async {
    final out = <Map<String, Object?>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
    ];
    for (final m in history) {
      if (m.role == 'assistant') {
        if (m.text.isNotEmpty) out.add({'role': 'assistant', 'content': m.text});
        continue;
      }
      if (m.attachments.isEmpty) {
        out.add({'role': 'user', 'content': m.text});
        continue;
      }
      final parts = <Map<String, Object?>>[];
      for (final a in m.attachments) {
        final f = File(a.path);
        if (!f.existsSync()) {
          parts.add({'type': 'text', 'text': '[${a.name} is no longer on this device]'});
          continue;
        }
        if (a.isImage) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:${a.mime};base64,${base64Encode(await f.readAsBytes())}'},
          });
        } else if (a.isText) {
          var body = await f.readAsString().catchError((_) => '');
          if (body.length > 200000) body = '${body.substring(0, 200000)}\n…[truncated]';
          parts.add({'type': 'text', 'text': 'File ${a.name}:\n```\n$body\n```'});
        } else {
          parts.add({
            'type': 'file',
            'file': {'filename': a.name, 'file_data': 'data:${a.mime};base64,${base64Encode(await f.readAsBytes())}'},
          });
        }
      }
      if (m.text.isNotEmpty) parts.add({'type': 'text', 'text': m.text});
      out.add({'role': 'user', 'content': parts});
    }
    return out;
  }

  Stream<AiDelta> stream({required String model, required List<Map<String, Object?>> messages, bool reasoning = false}) async* {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _http = http;
    try {
      final req = await http.postUrl(endpoint ?? Uri.parse(gateway.endpoint));
      req.headers
        ..set('authorization', 'Bearer $apiKey')
        ..set('content-type', 'application/json')
        ..set('accept', 'text/event-stream');
      if (gateway == AiGateway.openrouter) {
        req.headers
          ..set('http-referer', 'https://github.com/dagmawibabi/mentos')
          ..set('x-title', 'Mentos');
      }
      req.add(utf8.encode(jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
        if (reasoning && gateway == AiGateway.openrouter) 'reasoning': {'effort': 'medium'},
      })));
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        final body = await utf8.decodeStream(res).catchError((_) => '');
        throw AiError(_errorText(res.statusCode, body), status: res.statusCode);
      }
      final lines = res.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (j['error'] != null) {
          final err = j['error'];
          throw AiError(err is Map ? '${err['message'] ?? err}' : '$err');
        }
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        if (delta is! Map) continue;
        final text = delta['content'] is String ? delta['content'] as String : '';
        final thought = delta['reasoning'] is String
            ? delta['reasoning'] as String
            : (delta['reasoning_content'] is String ? delta['reasoning_content'] as String : '');
        if (text.isNotEmpty || thought.isNotEmpty) {
          yield AiDelta(text: text, reasoning: thought, model: j['model'] as String?);
        }
      }
    } on SocketException catch (e) {
      if (_http == null) return; // cancelled
      throw AiError('No connection: ${e.message}');
    } on HttpException catch (e) {
      if (_http == null) return;
      throw AiError(e.message);
    } finally {
      http.close(force: true);
      if (identical(_http, http)) _http = null;
    }
  }

  static String _errorText(int status, String body) {
    String? detail;
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      detail = err is Map ? '${err['message'] ?? ''}' : (err is String ? err : null);
    } catch (_) {}
    final hint = switch (status) {
      401 || 403 => 'The key was refused. Check it in AI settings.',
      402 => 'The account behind this key is out of credit.',
      404 => 'This model isn\'t available on your gateway.',
      429 => 'Rate limited. Wait a moment and try again.',
      _ => 'The gateway answered $status.',
    };
    return detail == null || detail.isEmpty ? hint : '$hint\n$detail';
  }
}
