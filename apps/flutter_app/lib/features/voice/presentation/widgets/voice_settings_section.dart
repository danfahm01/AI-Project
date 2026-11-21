import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/widgets/common_widgets.dart';
import '../../../../domain/entities/ai_provider.dart';
import '../../../../domain/entities/user_preferences.dart';
import '../../../../providers/preferences_controller.dart';

/// Voice settings shared by the settings screen and the voice screen's sheet.
/// Provider-dependent options (voice, language, speed, speech detection) are
/// shown only when the selected realtime model reports support for them.
class VoiceSettingsSection extends ConsumerWidget {
  const VoiceSettingsSection({super.key, required this.preferences, required this.catalog, this.fallbackProviderId});

  final UserPreferences preferences;
  final ProviderCatalog catalog;

  /// Provider whose realtime model is used when none was chosen (e.g. the open
  /// conversation's provider), so the options match what voice mode will use.
  final String? fallbackProviderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(preferencesControllerProvider.notifier);
    final realtimeModels = catalog.realtimeModels;
    final voiceModel = selectVoiceModel(catalog, preferences, fallbackProviderId: fallbackProviderId);
    final capabilities = voiceModel?.model.capabilities;
    final handsFree = preferences.voiceMode == VoiceMode.handsFree;
    void update(Future<void> Function() action) => runGuarded(context, action);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (voiceModel != null)
          ListTile(
            title: const Text('Voice model'),
            subtitle: Text(voiceModel.provider.displayName),
            trailing: realtimeModels.length < 2
                ? Text(voiceModel.model.displayName, style: theme.textTheme.bodyLarge)
                : DropdownButton<int>(
                    key: const ValueKey('voice-model-picker'),
                    value: realtimeModels.indexWhere(
                      (c) => c.provider.id == voiceModel.provider.id && c.model.id == voiceModel.model.id,
                    ),
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final (index, choice) in realtimeModels.indexed)
                        DropdownMenuItem(
                          value: index,
                          child: Text('${choice.model.displayName} · ${choice.provider.displayName}'),
                        ),
                    ],
                    onChanged: (index) {
                      if (index != null) update(() => controller.setVoiceModel(realtimeModels[index]));
                    },
                  ),
          ),
        ListTile(
          title: const Text('Conversation mode'),
          subtitle: Text(
            handsFree
                ? 'Talk naturally; your turn ends when you stop speaking.'
                : 'Hold the microphone button while you speak.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<VoiceMode>(
            segments: const [
              ButtonSegment(value: VoiceMode.handsFree, icon: Icon(Icons.hearing_rounded), label: Text('Hands-free')),
              ButtonSegment(
                value: VoiceMode.pushToTalk,
                icon: Icon(Icons.touch_app_outlined),
                label: Text('Push to talk'),
              ),
            ],
            selected: {preferences.voiceMode},
            onSelectionChanged: (selection) => update(() => controller.setVoiceMode(selection.first)),
          ),
        ),
        if (capabilities?.serverVad ?? false)
          SwitchListTile(
            title: const Text('Automatic speech detection'),
            subtitle: const Text('Detect when you start and stop speaking'),
            value: preferences.autoSpeechDetection,
            onChanged: handsFree ? (value) => update(() => controller.setAutoSpeechDetection(value)) : null,
          ),
        if (capabilities != null && capabilities.voices.isNotEmpty)
          ListTile(
            title: const Text('Voice'),
            trailing: DropdownButton<String?>(
              value: capabilities.voices.any((v) => v.id == preferences.voiceName) ? preferences.voiceName : null,
              hint: const Text('Default'),
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('Default')),
                for (final voice in capabilities.voices)
                  DropdownMenuItem(value: voice.id, child: Text(voice.displayName)),
              ],
              onChanged: (value) => update(() => controller.setVoice(value)),
            ),
          ),
        if (capabilities != null && capabilities.languages.isNotEmpty)
          ListTile(
            title: const Text('Language'),
            trailing: DropdownButton<String?>(
              value: capabilities.languages.contains(preferences.language) ? preferences.language : null,
              hint: const Text('Automatic'),
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('Automatic')),
                for (final language in capabilities.languages) DropdownMenuItem(value: language, child: Text(language)),
              ],
              onChanged: (value) => update(() => controller.setLanguage(value)),
            ),
          ),
        if (capabilities?.speakingRate case final range?)
          _SpeakingRateTile(
            key: ValueKey('rate-${voiceModel?.provider.id}-${voiceModel?.model.id}'),
            range: range,
            value: preferences.speakingRate ?? range.defaultValue,
            onChanged: (value) => update(() => controller.setSpeakingRate(value)),
          ),
        if (voiceModel == null)
          ListTile(
            leading: Icon(Icons.info_outline_rounded, color: theme.colorScheme.onSurfaceVariant),
            title: const Text('Voice, language and speed'),
            subtitle: const Text('These options appear when the server has a realtime voice model configured.'),
          ),
        const Divider(indent: 16, endIndent: 16),
        const ListTile(title: Text('Microphone processing'), dense: true),
        SwitchListTile(
          title: const Text('Echo cancellation'),
          value: preferences.audioSettings.echoCancellation,
          onChanged: (value) =>
              update(() => controller.setAudioSettings(preferences.audioSettings.copyWith(echoCancellation: value))),
        ),
        SwitchListTile(
          title: const Text('Noise suppression'),
          value: preferences.audioSettings.noiseSuppression,
          onChanged: (value) =>
              update(() => controller.setAudioSettings(preferences.audioSettings.copyWith(noiseSuppression: value))),
        ),
        SwitchListTile(
          title: const Text('Automatic gain control'),
          value: preferences.audioSettings.autoGainControl,
          onChanged: (value) =>
              update(() => controller.setAudioSettings(preferences.audioSettings.copyWith(autoGainControl: value))),
        ),
      ],
    );
  }
}

class _SpeakingRateTile extends StatefulWidget {
  const _SpeakingRateTile({super.key, required this.range, required this.value, required this.onChanged});

  final NumericRange range;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_SpeakingRateTile> createState() => _SpeakingRateTileState();
}

class _SpeakingRateTileState extends State<_SpeakingRateTile> {
  late double _value = widget.value.clamp(widget.range.min, widget.range.max);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text('Speaking speed (${_value.toStringAsFixed(2)}×)'),
      subtitle: Slider(
        min: widget.range.min,
        max: widget.range.max,
        divisions: ((widget.range.max - widget.range.min) / 0.05).round(),
        value: _value,
        label: '${_value.toStringAsFixed(2)}×',
        onChanged: (value) => setState(() => _value = value),
        onChangeEnd: widget.onChanged,
      ),
    );
  }
}
