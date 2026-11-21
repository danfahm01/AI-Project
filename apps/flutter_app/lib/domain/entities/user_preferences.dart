enum ThemePreference { system, light, dark }

enum VoiceMode {
  handsFree('hands_free'),
  pushToTalk('push_to_talk');

  const VoiceMode(this.wireName);

  final String wireName;

  static VoiceMode fromWire(String value) =>
      VoiceMode.values.firstWhere((mode) => mode.wireName == value, orElse: () => VoiceMode.handsFree);
}

class AudioSettings {
  const AudioSettings({this.echoCancellation = true, this.noiseSuppression = true, this.autoGainControl = true});

  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;

  AudioSettings copyWith({bool? echoCancellation, bool? noiseSuppression, bool? autoGainControl}) => AudioSettings(
    echoCancellation: echoCancellation ?? this.echoCancellation,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    autoGainControl: autoGainControl ?? this.autoGainControl,
  );

  Map<String, Object?> toJson() => {
    'echo_cancellation': echoCancellation,
    'noise_suppression': noiseSuppression,
    'auto_gain_control': autoGainControl,
  };
}

class UserPreferences {
  const UserPreferences({
    this.theme = ThemePreference.system,
    this.language,
    this.defaultProvider,
    this.defaultModel,
    this.voiceProvider,
    this.voiceModel,
    this.voiceName,
    this.speakingRate,
    this.autoSpeechDetection = true,
    this.voiceMode = VoiceMode.handsFree,
    this.audioSettings = const AudioSettings(),
  });

  final ThemePreference theme;
  final String? language;

  /// Text chat model for new conversations.
  final String? defaultProvider;
  final String? defaultModel;

  /// Realtime model for voice mode (chosen separately from the text model).
  final String? voiceProvider;
  final String? voiceModel;

  /// Provider-specific voice ID; `null` uses the model's default voice.
  final String? voiceName;
  final double? speakingRate;
  final bool autoSpeechDetection;
  final VoiceMode voiceMode;
  final AudioSettings audioSettings;
}
