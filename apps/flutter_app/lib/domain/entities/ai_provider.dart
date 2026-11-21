/// Provider/model catalog as reported by the backend. The UI only offers
/// options that appear here, so unsupported settings are never shown.
library;

class VoiceOption {
  const VoiceOption({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

class NumericRange {
  const NumericRange({required this.min, required this.max, required this.defaultValue});

  final double min;
  final double max;
  final double defaultValue;
}

class ModelCapabilities {
  const ModelCapabilities({
    this.textStreaming = false,
    this.realtimeVoice = false,
    this.serverVad = false,
    this.interruption = false,
    this.imageInput = false,
    this.pdfInput = false,
    this.voices = const [],
    this.languages = const [],
    this.speakingRate,
  });

  final bool textStreaming;
  final bool realtimeVoice;
  final bool serverVad;
  final bool interruption;
  final bool imageInput;
  final bool pdfInput;
  final List<VoiceOption> voices;
  final List<String> languages;
  final NumericRange? speakingRate;

  bool get acceptsAttachments => imageInput || pdfInput;
}

class AIModelInfo {
  const AIModelInfo({required this.id, required this.displayName, required this.capabilities, this.isDefault = false});

  final String id;
  final String displayName;
  final bool isDefault;
  final ModelCapabilities capabilities;
}

class AIProviderInfo {
  const AIProviderInfo({required this.id, required this.displayName, required this.models, this.isDefault = false});

  final String id;
  final String displayName;
  final bool isDefault;
  final List<AIModelInfo> models;

  AIModelInfo? get defaultModel => models.where((m) => m.isDefault).firstOrNull ?? models.firstOrNull;
}

typedef ModelSelection = ({AIProviderInfo provider, AIModelInfo model});

class ProviderCatalog {
  const ProviderCatalog({required this.providers, this.defaultProviderId});

  static const empty = ProviderCatalog(providers: []);

  final List<AIProviderInfo> providers;
  final String? defaultProviderId;

  bool get isEmpty => providers.isEmpty;

  /// Resolves the effective model: the explicit choice if it exists, otherwise
  /// the server default.
  ModelSelection? resolve({String? providerId, String? modelId}) {
    final provider = providers.where((p) => p.id == providerId).firstOrNull;
    if (provider != null) {
      final model = provider.models.where((m) => m.id == modelId).firstOrNull ?? provider.defaultModel;
      if (model != null) return (provider: provider, model: model);
    }
    final fallbackProvider = providers.where((p) => p.id == defaultProviderId).firstOrNull ?? providers.firstOrNull;
    final fallbackModel = fallbackProvider?.defaultModel;
    if (fallbackProvider == null || fallbackModel == null) return null;
    return (provider: fallbackProvider, model: fallbackModel);
  }

  /// Every realtime voice model, grouped by provider in catalog order.
  List<ModelSelection> get realtimeModels => [
    for (final provider in providers)
      for (final model in provider.models)
        if (model.capabilities.realtimeVoice) (provider: provider, model: model),
  ];

  /// The realtime voice model to use: the given model if it supports realtime
  /// voice, else the first realtime model of the given provider, of the default
  /// provider, or of any provider.
  ModelSelection? realtimeVoice({String? providerId, String? modelId}) {
    final candidates = realtimeModels;
    if (candidates.isEmpty) return null;
    return candidates.where((c) => c.provider.id == providerId && c.model.id == modelId).firstOrNull ??
        candidates.where((c) => c.provider.id == providerId).firstOrNull ??
        candidates.where((c) => c.provider.id == defaultProviderId).firstOrNull ??
        candidates.first;
  }
}
