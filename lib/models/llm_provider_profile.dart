/// Represents one configured LLM provider (a base URL + API key + model).
/// PrivateAgent can hold several of these and will automatically try the
/// next one in the list if the current one is rate-limited, times out, or
/// errors — so the app keeps working fast even if one free provider is busy.
class LlmProviderProfile {
  String name;
  String baseUrl;
  String apiKey;
  String model;

  LlmProviderProfile({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  factory LlmProviderProfile.fromJson(Map<String, dynamic> json) {
    return LlmProviderProfile(
      name: json['name'] as String? ?? 'Provider',
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
  };

  bool get isConfigured => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;
}

/// Ready-to-use presets for well-known providers that offer fast, free tiers.
/// The API key field is left blank for the user to fill in.
class LlmProviderPresets {
  static const List<Map<String, String>> presets = [
    {
      'name': 'Groq — Llama 3.1 8B (fastest, best for agent tasks)',
      'baseUrl': 'https://api.groq.com/openai/v1',
      'model': 'llama-3.1-8b-instant',
    },
    {
      'name': 'Groq — Llama 3.3 70B (smarter, still very fast)',
      'baseUrl': 'https://api.groq.com/openai/v1',
      'model': 'llama-3.3-70b-versatile',
    },
    {
      'name': 'Groq — Llama 4 Scout',
      'baseUrl': 'https://api.groq.com/openai/v1',
      'model': 'meta-llama/llama-4-scout-17b-16e-instruct',
    },
    {
      'name': 'Cerebras — Llama 3.3 70B (very fast, 1M tokens/day free)',
      'baseUrl': 'https://api.cerebras.ai/v1',
      'model': 'llama-3.3-70b',
    },
    {
      'name': 'NVIDIA NIM — GLM 5.2',
      'baseUrl': 'https://integrate.api.nvidia.com/v1',
      'model': 'z-ai/glm-5.2',
    },
    {
      'name': 'OpenRouter — free tier',
      'baseUrl': 'https://openrouter.ai/api/v1',
      'model': 'meta-llama/llama-3.1-8b-instruct:free',
    },
    {
      'name': 'DeepSeek',
      'baseUrl': 'https://api.deepseek.com',
      'model': 'deepseek-chat',
    },
    {
      'name': 'Together AI — free',
      'baseUrl': 'https://api.together.xyz/v1',
      'model': 'meta-llama/Llama-3.3-70B-Instruct-Turbo-Free',
    },
    {
      'name': 'SambaNova',
      'baseUrl': 'https://api.sambanova.ai/v1',
      'model': 'Meta-Llama-3.1-8B-Instruct',
    },
    {
      'name': 'Mistral',
      'baseUrl': 'https://api.mistral.ai/v1',
      'model': 'mistral-small-latest',
    },
    {
      'name': 'Custom / other OpenAI-compatible provider',
      'baseUrl': '',
      'model': '',
    },
  ];
}
