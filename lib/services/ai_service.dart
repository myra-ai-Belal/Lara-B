import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/agent_action.dart';
import '../models/llm_provider_profile.dart';

class AiResponse {
  final String content;
  final int totalTokens;
  AiResponse(this.content, this.totalTokens);
}

class AiService {
  static const String _defaultBaseUrl = 'https://api.deepseek.com';
  static const String _defaultModel = 'deepseek-chat';
  static const String nvidiaBaseUrl = 'https://integrate.api.nvidia.com/v1';
  static const String nvidiaDefaultModel = 'z-ai/glm-5.2';

  static const List<String> nvidiaFreeChatModels = [
    'z-ai/glm-5.2',
    'nvidia/nemotron-3-nano-30b-a3b',
    'nvidia/nemotron-3-super-120b-a12b',
    'nvidia/nemotron-3-ultra-550b-a55b',
    'nvidia/nvidia-nemotron-nano-9b-v2',
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'meta/llama-3.3-70b-instruct',
    'meta/llama-3.2-3b-instruct',
    'meta/llama-3.1-8b-instruct',
    'meta/llama-3.1-70b-instruct',
    'mistralai/mistral-nemotron',
    'deepseek-ai/deepseek-v4-flash',
    'deepseek-ai/deepseek-v4-pro',
  ];

  static bool isNvidiaBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase() == 'integrate.api.nvidia.com';
  }

  static List<String> filterNvidiaFreeModels(Iterable<String> models) {
    final availableModels = models.toSet();
    return nvidiaFreeChatModels
        .where(availableModels.contains)
        .toList(growable: false);
  }

  // ---- Legacy single-provider fields (kept for backward compatibility with
  // existing Settings UI). These now always mirror the active provider. ----
  String? _apiKey;
  String _baseUrl = _defaultBaseUrl;
  String _model = _defaultModel;

  // ---- Multiple provider profiles with automatic fallback ----
  List<LlmProviderProfile> _providers = [];
  int _activeProviderIndex = 0; // last-known-good provider; tried first

  int _maxSteps = 15;
  bool _disableMaxSteps = false;
  double _temperature = 1.0;
  int _maxTokens = 1024;
  bool _useScreenCompression = true;
  bool _useSystemPrompt = true;
  final List<Map<String, String>> _conversationHistory = [];

  static const String _systemPrompt = '''
You are PrivateAgent, a helpful AI assistant that controls an Android phone. You can perform device actions and also have normal conversations.

When the user wants to perform a device action, you MUST respond with ONLY a JSON object (no markdown, no code fences, no extra text) in this exact format:
{"action": "action_name", "params": {"key": "value"}, "response": "What you say to the user"}

Available actions and their params:

SIMPLE ACTIONS (single step only):
- open_app: {"app_name": "YouTube"} - ONLY use this when the user JUST wants to open an app and nothing else
- make_call: {"contact_name": "Mom"} OR {"phone_number": "1234567890"} - Makes a phone call
- send_sms: {"contact_name": "John", "message": "Hello"} OR {"phone_number": "123", "message": "Hi"} - Sends SMS
- search_contact: {"query": "John"} - Searches contacts
- set_alarm: {"hour": 7, "minute": 30, "label": "Wake up"} - Sets an alarm
- set_volume: {"level": 50} - Sets volume (0-100)
- set_brightness: {"level": 50} - Sets brightness (0-100)
- read_screen: {} - Read what's currently on the screen
- press_back: {} - Press the back button

MULTI-STEP TASK (for anything that requires more than one action):
- execute_task: {"goal": "description of the full task"} - Automatically reads screen, taps, scrolls, types step by step

CRITICAL RULES:
1. If the user request contains "and" or involves MULTIPLE steps (open + search, open + send, open + find, etc.), you MUST use execute_task. NEVER use open_app for these.
2. execute_task handles everything: opening apps, finding elements, clicking, typing, scrolling.

Examples of when to use execute_task:
- "Create a new alarm for 7 AM" → execute_task with goal "Create a new alarm for 7 AM"
- "Go to YouTube and search for cats" → execute_task
- "Open WhatsApp and send hello to John" → execute_task
- "Open Settings and turn on WiFi" → execute_task
- "Search for restaurants on Google Maps" → execute_task

Examples of when to use open_app:
- "Open YouTube" → open_app (just opening, no further action)
- "Open Settings" → open_app (just opening)

For normal conversation (questions, chat, info requests), just respond with plain text naturally.
''';

  static const String _chatSystemPrompt = '''
You are PrivateAgent, a helpful conversational AI assistant. 
Provide direct, natural, and friendly text responses. You cannot perform device actions or run tools. 
Answer questions, explain concepts, brainstorm, write emails/messages, and chat with the user in plain text or markdown format.
''';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final providersJson = prefs.getString('llm_providers');
    if (providersJson != null && providersJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(providersJson);
        _providers = decoded
            .map((e) => LlmProviderProfile.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _providers = [];
      }
    }

    if (_providers.isEmpty) {
      final legacyKey = prefs.getString('api_key');
      final legacyBaseUrl = prefs.getString('api_base_url') ?? _defaultBaseUrl;
      final legacyModel = prefs.getString('api_model') ?? _defaultModel;
      _providers = [
        LlmProviderProfile(
          name: 'Primary',
          baseUrl: legacyBaseUrl,
          apiKey: legacyKey ?? '',
          model: legacyModel,
        ),
      ];
    }

    _activeProviderIndex = prefs.getInt('llm_active_provider_index') ?? 0;
    if (_activeProviderIndex >= _providers.length) {
      _activeProviderIndex = 0;
    }

    _syncLegacyFieldsFromProviders();

    _maxSteps = prefs.getInt('api_max_steps') ?? 15;
    _disableMaxSteps = prefs.getBool('api_disable_max_steps') ?? false;
    _temperature = prefs.getDouble('api_temperature') ?? 1.0;
    _maxTokens = prefs.getInt('api_max_tokens') ?? 1024;
    _useScreenCompression = prefs.getBool('api_use_screen_compression') ?? true;
    _useSystemPrompt = prefs.getBool('api_use_system_prompt') ?? true;
  }

  void _syncLegacyFieldsFromProviders() {
    if (_providers.isEmpty) return;
    final active = _providers[_activeProviderIndex];
    _apiKey = active.apiKey;
    _baseUrl = active.baseUrl;
    _model = active.model;
  }

  Future<void> saveProviders(List<LlmProviderProfile> providers) async {
    final prefs = await SharedPreferences.getInstance();
    _providers = providers;
    if (_activeProviderIndex >= _providers.length) {
      _activeProviderIndex = 0;
    }
    await prefs.setString(
      'llm_providers',
      jsonEncode(_providers.map((p) => p.toJson()).toList()),
    );
    _syncLegacyFieldsFromProviders();
    if (_providers.isNotEmpty) {
      await prefs.setString('api_key', _providers[_activeProviderIndex].apiKey);
      await prefs.setString('api_base_url', _providers[_activeProviderIndex].baseUrl);
      await prefs.setString('api_model', _providers[_activeProviderIndex].model);
    }
  }

  List<LlmProviderProfile> get providers => List.unmodifiable(_providers);
  int get activeProviderIndex => _activeProviderIndex;

  Future<void> saveSettings({
    required String apiKey,
    String? baseUrl,
    String? model,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    String cleanApiKey = apiKey.trim();
    if (cleanApiKey.toLowerCase().startsWith('bearer ')) {
      cleanApiKey = cleanApiKey.substring(7).trim();
    }

    _apiKey = cleanApiKey;
    await prefs.setString('api_key', cleanApiKey);

    if (baseUrl != null && baseUrl.isNotEmpty) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (model != null && model.isNotEmpty) {
      _model = model;
      await prefs.setString('api_model', model);
    }

    if (_providers.isEmpty) {
      _providers = [
        LlmProviderProfile(
          name: 'Primary',
          baseUrl: _baseUrl,
          apiKey: _apiKey ?? '',
          model: _model,
        ),
      ];
    } else {
      _providers[_activeProviderIndex] = LlmProviderProfile(
        name: _providers[_activeProviderIndex].name,
        baseUrl: _baseUrl,
        apiKey: _apiKey ?? '',
        model: _model,
      );
    }
    await prefs.setString(
      'llm_providers',
      jsonEncode(_providers.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> saveMaxSteps(int steps) async {
    final prefs = await SharedPreferences.getInstance();
    _maxSteps = steps;
    await prefs.setInt('api_max_steps', steps);
  }

  Future<void> saveDisableMaxSteps(bool disable) async {
    final prefs = await SharedPreferences.getInstance();
    _disableMaxSteps = disable;
    await prefs.setBool('api_disable_max_steps', disable);
  }

  Future<void> saveAdvancedSettings({
    required double temperature,
    required int maxTokens,
    required bool useScreenCompression,
    required bool useSystemPrompt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _temperature = temperature;
    _maxTokens = maxTokens;
    _useScreenCompression = useScreenCompression;
    _useSystemPrompt = useSystemPrompt;
    await prefs.setDouble('api_temperature', temperature);
    await prefs.setInt('api_max_tokens', maxTokens);
    await prefs.setBool('api_use_screen_compression', useScreenCompression);
    await prefs.setBool('api_use_system_prompt', useSystemPrompt);
  }

  bool get isConfigured =>
      _providers.any((p) => p.isConfigured) ||
      (_apiKey != null && _apiKey!.isNotEmpty);
  String get baseUrl => _baseUrl;
  String get model => _model;
  String get apiKey => _apiKey ?? '';
  int get maxSteps => _disableMaxSteps ? 999 : _maxSteps;
  int get rawMaxSteps => _maxSteps;
  bool get disableMaxSteps => _disableMaxSteps;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  bool get useScreenCompression => _useScreenCompression;
  bool get useSystemPrompt => _useSystemPrompt;

  int _effectiveMaxTokensFor(String baseUrl, String model) {
    if (isNvidiaBaseUrl(baseUrl) && model == nvidiaDefaultModel && _maxTokens < 4096) {
      return 4096;
    }
    return _maxTokens;
  }

  void clearHistory() {
    _conversationHistory.clear();
  }

  void addHistoryMessage(String role, String content) {
    _conversationHistory.add({'role': role, 'content': content});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
  }

  List<int> _providerTryOrder() {
    final configuredIndexes = <int>[
      for (int i = 0; i < _providers.length; i++)
        if (_providers[i].isConfigured) i,
    ];
    if (configuredIndexes.isEmpty) return [];
    configuredIndexes.sort((a, b) {
      if (a == _activeProviderIndex) return -1;
      if (b == _activeProviderIndex) return 1;
      return 0;
    });
    return configuredIndexes;
  }

  bool _isRetryableStatus(int statusCode) {
    return statusCode == 429 || statusCode >= 500;
  }

  String _buildRequestUrl(String baseUrl) {
    String requestUrl = baseUrl;
    if (requestUrl.endsWith('/chat/completions')) return requestUrl;
    if (requestUrl.endsWith('/')) return '${requestUrl}chat/completions';
    return '$requestUrl/chat/completions';
  }

  Future<String> sendMessage(String message, {bool isAgentMode = true}) async {
    final tryOrder = _providerTryOrder();
    if (tryOrder.isEmpty) {
      throw Exception('No AI provider is configured. Please go to Settings.');
    }

    _conversationHistory.add({'role': 'user', 'content': message});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    Object? lastError;
    for (final providerIndex in tryOrder) {
      final provider = _providers[providerIndex];
      try {
        final systemPrompt = isAgentMode ? _systemPrompt : _chatSystemPrompt;
        final messages = [
          if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
          ..._conversationHistory,
        ];

        final requestUrl = _buildRequestUrl(provider.baseUrl);
        final requestBody = jsonEncode({
          'model': provider.model,
          'messages': messages,
          'temperature': _temperature,
          'max_tokens': _effectiveMaxTokensFor(provider.baseUrl, provider.model),
        });

        developer.log('API Request [${provider.name}]: $requestUrl', name: 'AiService');

        final response = await http
            .post(
              Uri.parse(requestUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${provider.apiKey}',
                'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
                'X-Title': 'Lara AI',
              },
              body: requestBody,
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          if (_isRetryableStatus(response.statusCode)) {
            lastError = Exception('${provider.name}: HTTP ${response.statusCode}');
            continue;
          }
          throw Exception('API error (${response.statusCode}): ${response.body}');
        }

        final data = jsonDecode(response.body);
        if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
          lastError = Exception('${provider.name}: unexpected response format');
          continue;
        }

        String assistantMessage = data['choices'][0]['message']['content'] as String;
        assistantMessage = assistantMessage
            .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
            .trim();

        if (assistantMessage.isEmpty) {
          lastError = Exception('${provider.name}: empty response');
          continue;
        }

        _activeProviderIndex = providerIndex;
        _saveActiveProviderIndex();
        _conversationHistory.add({'role': 'assistant', 'content': assistantMessage});
        return assistantMessage;
      } catch (e) {
        lastError = e;
        continue;
      }
    }

    throw Exception('All AI providers failed. Last error: $lastError');
  }

  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
  }) async* {
    final tryOrder = _providerTryOrder();
    if (tryOrder.isEmpty) {
      throw Exception('No AI provider is configured. Please go to Settings.');
    }
    final provider = _providers[tryOrder.first];

    _conversationHistory.add({'role': 'user', 'content': message});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    try {
      final systemPrompt = isAgentMode ? _systemPrompt : _chatSystemPrompt;
      final messages = [
        if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
        ..._conversationHistory,
      ];

      final requestUrl = _buildRequestUrl(provider.baseUrl);

      final client = http.Client();
      final request = http.Request('POST', Uri.parse(requestUrl));
      request.headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${provider.apiKey}',
        'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
        'X-Title': 'Lara AI',
      });

      request.body = jsonEncode({
        'model': provider.model,
        'messages': messages,
        'temperature': _temperature,
        'max_tokens': _effectiveMaxTokensFor(provider.baseUrl, provider.model),
        'stream': true,
      });

      final response = await client.send(request).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        client.close();
        throw Exception('API error (${response.statusCode}): $body');
      }

      final accumulatedContent = StringBuffer();
      bool inThinkBlock = false;

      final lineStream = response.stream.transform(utf8.decoder).transform(const LineSplitter());

      await for (final line in lineStream) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;
        if (trimmedLine.startsWith('data:')) {
          final dataStr = trimmedLine.substring(5).trim();
          if (dataStr == '[DONE]') break;
          try {
            final json = jsonDecode(dataStr);
            if (json is Map && json['choices'] is List) {
              final choices = json['choices'] as List;
              if (choices.isNotEmpty) {
                final choice = choices[0];
                if (choice is! Map) continue;
                final rawDelta = choice['delta'];
                final delta = rawDelta is Map ? rawDelta : const {};
                final rawContent = delta['content'];
                if (rawContent is String && rawContent.isNotEmpty) {
                  final content = rawContent;
                  accumulatedContent.write(content);

                  if (content.contains('<think>')) {
                    inThinkBlock = true;
                    final parts = content.split('<think>');
                    if (parts[0].isNotEmpty) yield parts[0];
                  } else if (content.contains('</think>')) {
                    inThinkBlock = false;
                    final parts = content.split('</think>');
                    if (parts.length > 1 && parts[1].isNotEmpty) yield parts[1];
                  } else if (!inThinkBlock) {
                    yield content;
                  }
                }
                if (choice['finish_reason'] != null) break;
              }
            }
          } catch (_) {}
        }
      }

      client.close();
      _activeProviderIndex = tryOrder.first;
      _saveActiveProviderIndex();

      String finalResponse = accumulatedContent.toString().trim();
      finalResponse = finalResponse.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();

      if (finalResponse.isEmpty) {
        throw Exception('The model finished without a visible answer. Increase Max Tokens or try another model.');
      }
      _conversationHistory.add({'role': 'assistant', 'content': finalResponse});
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    }
  }

  Future<AiResponse> sendTaskMessage(String systemPrompt, String prompt) async {
    final tryOrder = _providerTryOrder();
    if (tryOrder.isEmpty) {
      throw Exception('No AI provider is configured. Please go to Settings.');
    }

    Object? lastError;

    for (final providerIndex in tryOrder) {
      final provider = _providers[providerIndex];

      const maxRetriesPerProvider = 1;
      for (int attempt = 0; attempt <= maxRetriesPerProvider; attempt++) {
        try {
          final messages = [
            if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': prompt},
          ];

          final requestUrl = _buildRequestUrl(provider.baseUrl);

          final response = await http
              .post(
                Uri.parse(requestUrl),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer ${provider.apiKey}',
                  'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
                  'X-Title': 'Lara AI',
                },
                body: jsonEncode({
                  'model': provider.model,
                  'messages': messages,
                  'temperature': _temperature,
                  'max_tokens': _effectiveMaxTokensFor(provider.baseUrl, provider.model),
                }),
              )
              .timeout(const Duration(seconds: 20));

          if (response.statusCode != 200) {
            if (_isRetryableStatus(response.statusCode)) {
              lastError = Exception('${provider.name}: HTTP ${response.statusCode}');
              break;
            }
            String errorMessage = response.body;
            try {
              final decoded = jsonDecode(response.body);
              if (decoded is Map<String, dynamic> && decoded['error'] != null) {
                errorMessage = decoded['error'] is Map
                    ? (decoded['error']['message']?.toString() ?? response.body)
                    : decoded['error'].toString();
              }
            } catch (_) {}
            throw Exception('API error (${response.statusCode}): $errorMessage');
          }

          final data = jsonDecode(response.body);
          if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
            lastError = Exception('${provider.name}: unexpected response format');
            break;
          }

          String content = data['choices'][0]['message']['content'] as String;
          content = content.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();

          if (content.isEmpty) {
            lastError = Exception('${provider.name}: empty response');
            break;
          }

          int tokens = 0;
          if (data.containsKey('usage') && data['usage']['total_tokens'] != null) {
            tokens = data['usage']['total_tokens'] as int;
          }

          _activeProviderIndex = providerIndex;
          _saveActiveProviderIndex();
          return AiResponse(content, tokens);
        } catch (e) {
          lastError = e;
          if (attempt < maxRetriesPerProvider) {
            await Future.delayed(const Duration(milliseconds: 500));
            continue;
          }
          break;
        }
      }
    }

    throw Exception('All AI providers failed. Last error: $lastError');
  }

  Future<void> _saveActiveProviderIndex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('llm_active_provider_index', _activeProviderIndex);
  }

  AgentAction? parseAction(String response) {
    try {
      final trimmed = response.trim();
      String jsonStr = trimmed;
      if (trimmed.startsWith('```')) {
        final lines = trimmed.split('\n');
        lines.removeAt(0);
        if (lines.isNotEmpty && lines.last.trim() == '```') {
          lines.removeLast();
        }
        jsonStr = lines.join('\n').trim();
      }

      if (jsonStr.startsWith('{') && !jsonStr.endsWith('}')) {
        jsonStr += '\n}';
      }

      if (jsonStr.startsWith('{') && jsonStr.contains('"action"')) {
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          if (json.containsKey('action')) {
            return AgentAction.fromJson(json);
          }
        } catch (e) {
          if (e.toString().contains('Unexpected end of input')) {
            jsonStr += '\n}';
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            if (json.containsKey('action')) {
              return AgentAction.fromJson(json);
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<String>> fetchAvailableModels(String baseUrl, String apiKey) async {
    try {
      String cleanBaseUrl = baseUrl;
      if (cleanBaseUrl.endsWith('/chat/completions')) {
        cleanBaseUrl = cleanBaseUrl.replaceAll('/chat/completions', '');
      }

      final response = await http.get(
        Uri.parse('$cleanBaseUrl/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<String> models;
        if (data is Map && data.containsKey('data')) {
          final modelsList = data['data'] as List;
          models = modelsList.map((m) => m['id'].toString()).toList();
        } else if (data is List) {
          models = data.map((m) => m['id'].toString()).toList();
        } else {
          return [];
        }

        if (isNvidiaBaseUrl(cleanBaseUrl)) {
          return filterNvidiaFreeModels(models);
        }
        models.sort();
        return models;
      }
      return [];
    } catch (e) {
      print('Error fetching models: $e');
      return [];
    }
  }
}
