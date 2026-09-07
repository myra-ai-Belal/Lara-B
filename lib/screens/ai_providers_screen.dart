import 'package:flutter/material.dart';
import '../models/llm_provider_profile.dart';
import '../services/ai_service.dart';

/// Lets the user configure several AI providers at once. PrivateAgent tries
/// them in order (starting with whichever one worked last) and automatically
/// skips to the next one if a provider is rate-limited, slow, or errors —
/// so a single busy free-tier provider never makes the whole app feel slow.
class AiProvidersScreen extends StatefulWidget {
  final AiService aiService;
  const AiProvidersScreen({super.key, required this.aiService});

  @override
  State<AiProvidersScreen> createState() => _AiProvidersScreenState();
}

class _AiProvidersScreenState extends State<AiProvidersScreen> {
  late List<LlmProviderProfile> _providers;
  late int _activeIndex;

  @override
  void initState() {
    super.initState();
    _providers = List.of(widget.aiService.providers);
    _activeIndex = widget.aiService.activeProviderIndex;
    if (_providers.isEmpty) {
      _providers = [
        LlmProviderProfile(name: 'Primary', baseUrl: '', apiKey: '', model: ''),
      ];
    }
  }

  Future<void> _persist() async {
    await widget.aiService.saveProviders(_providers);
  }

  void _addFromPreset() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.all(12),
          itemCount: LlmProviderPresets.presets.length,
          itemBuilder: (context, i) {
            final preset = LlmProviderPresets.presets[i];
            return Card(
              color: const Color(0xFF25253D),
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(
                  preset['name']!,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: preset['model']!.isNotEmpty
                    ? Text(
                        preset['model']!,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      )
                    : null,
                onTap: () {
                  setState(() {
                    _providers.add(
                      LlmProviderProfile(
                        name: preset['name']!.split('—').first.trim(),
                        baseUrl: preset['baseUrl']!,
                        apiKey: '',
                        model: preset['model']!,
                      ),
                    );
                  });
                  _persist();
                  Navigator.pop(context);
                },
              ),
            );
          },
        ),
      ),
    );
  }

  void _editProvider(int index) {
    final provider = _providers[index];
    final nameCtrl = TextEditingController(text: provider.name);
    final urlCtrl = TextEditingController(text: provider.baseUrl);
    final keyCtrl = TextEditingController(text: provider.apiKey);
    final modelCtrl = TextEditingController(text: provider.model);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Edit provider', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogField(nameCtrl, 'Name'),
              _dialogField(urlCtrl, 'Base URL'),
              _dialogField(keyCtrl, 'API Key', obscure: true),
              _dialogField(modelCtrl, 'Model'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _providers[index] = LlmProviderProfile(
                  name: nameCtrl.text.trim().isEmpty ? 'Provider' : nameCtrl.text.trim(),
                  baseUrl: urlCtrl.text.trim(),
                  apiKey: keyCtrl.text.trim(),
                  model: modelCtrl.text.trim(),
                );
              });
              _persist();
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _dialogField(TextEditingController ctrl, String label, {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
        ),
      ),
    );
  }

  void _delete(int index) {
    setState(() {
      _providers.removeAt(index);
      if (_activeIndex >= _providers.length) _activeIndex = 0;
    });
    _persist();
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _providers.removeAt(oldIndex);
      _providers.insert(newIndex, item);
    });
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1E),
        title: const Text('AI Providers', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addFromPreset,
        backgroundColor: const Color(0xFF8B5CF6),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Add several providers for speed and reliability — Lara tries the first working one, and skips busy or rate-limited ones automatically. Drag ☰ to reorder priority.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _providers.length,
              onReorder: _reorder,
              itemBuilder: (context, index) {
                final p = _providers[index];
                final isActive = index == _activeIndex;
                return Card(
                  key: ValueKey('provider_$index-${p.name}'),
                  color: isActive ? const Color(0xFF2D2D4D) : const Color(0xFF1A1A2E),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: isActive
                        ? const BorderSide(color: Color(0xFF8B5CF6), width: 1.5)
                        : BorderSide.none,
                  ),
                  child: ListTile(
                    leading: Icon(
                      p.isConfigured ? Icons.check_circle : Icons.error_outline,
                      color: p.isConfigured ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    title: Text(p.name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      p.model.isEmpty ? 'Not configured yet — tap to edit' : p.model,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    onTap: () => _editProvider(index),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            color: Colors.white38,
                          ),
                          onPressed: () => _delete(index),
                        ),
                        const Icon(Icons.drag_handle, color: Colors.white24),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
