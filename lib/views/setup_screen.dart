import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/playlist_controller.dart';
import '../models/display_profile.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _serverController;
  late final TextEditingController _nameController;
  late final TextEditingController _pinController;
  bool _pinSaved = false;

  PlaylistController get _controller => Get.find<PlaylistController>();

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: _controller.serverAddress);
    _nameController = TextEditingController(
      text: _controller.deviceDisplayName,
    );
    _pinController = TextEditingController(text: _controller.servicePin);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _nameController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    await _controller.setServicePin(_pinController.text.trim());
    if (!mounted) return;
    setState(() => _pinSaved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pinSaved = false);
    });
  }

  Future<void> _checkConnection() async {
    await _controller.verifyServerConnection(
      serverAddress: _serverController.text,
      deviceName: _nameController.text,
    );
  }

  Future<void> _submitRequest() async {
    await _controller.submitRegistrationRequest(
      serverAddress: _serverController.text,
      deviceName: _nameController.text,
    );
  }

  Future<void> _refreshStatus() async {
    await _controller.refreshRegistrationStatus();
  }

  Future<void> _resetFlow() async {
    await _controller.resetRegistrationFlow();
    if (!mounted) return;
    setState(() {
      _serverController.text = _controller.serverAddress;
      _nameController.text = _controller.deviceDisplayName;
    });
  }

  Future<void> _refreshDisplays() async {
    await _controller.refreshAvailableDisplays();
  }

  Future<void> _selectDisplay(String displayId) async {
    await _controller.updateLocalDisplayPreferences(
      selectedDisplayId: displayId,
    );
  }

  Future<void> _setRotation(int rotation) async {
    await _controller.updateLocalDisplayPreferences(rotation: rotation);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewportConstraints) {
            return FocusTraversalGroup(
              // Позволяет D-pad на Android TV переключать фокус между полями ввода
              policy: OrderedTraversalPolicy(),
              child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: viewportConstraints.maxHeight - 48,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 880),
                    child: Obx(() {
                      final pending = _controller.isPendingApproval;
                      final busy = _controller.setupBusy;
                      final displayBusy = _controller.displayBusy;
                      final displays = _controller.availableDisplays;
                      final cardColor = pending
                          ? const Color(0xFFF8FBFF)
                          : Colors.white;

                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Первичная настройка устройства',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF1F2533),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFFD8DFEA),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x14000000),
                                  blurRadius: 24,
                                  offset: Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _InfoRow(
                                  label: 'ID устройства',
                                  value: _controller.deviceId,
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _serverController,
                                  enabled: !busy,
                                  decoration: const InputDecoration(
                                    labelText: 'Адрес сервера',
                                    hintText:
                                        'Например: 192.168.1.50:8088 или http://192.168.1.50:8088',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _nameController,
                                  enabled: !busy,
                                  decoration: const InputDecoration(
                                    labelText: 'Имя устройства',
                                    hintText: 'Например: Экран ресепшн',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Целевой экран',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: const Color(0xFF1F2533),
                                            ),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: busy || displayBusy
                                          ? null
                                          : _refreshDisplays,
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Обновить'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                if (displays.isEmpty)
                                  _SectionBox(
                                    child: Text(
                                      displayBusy
                                          ? 'Поиск экранов...'
                                          : 'Доступен текущий экран устройства.',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: const Color(0xFF5F6B84),
                                          ),
                                    ),
                                  )
                                else
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: [
                                      for (
                                        var index = 0;
                                        index < displays.length;
                                        index++
                                      )
                                        _DisplayCard(
                                          index: index,
                                          display: displays[index],
                                          selected:
                                              _controller.selectedDisplayId ==
                                              displays[index].id,
                                          onTap: busy || displayBusy
                                              ? null
                                              : () => _selectDisplay(
                                                  displays[index].id,
                                                ),
                                        ),
                                    ],
                                  ),
                                const SizedBox(height: 20),
                                Text(
                                  'Поворот контента',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: const Color(0xFF1F2533),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [0, 90, 180, 270]
                                      .map(
                                        (rotation) => ChoiceChip(
                                          label: Text('$rotation°'),
                                          selected:
                                              _controller
                                                  .localDisplayRotation ==
                                              rotation,
                                          onSelected: busy
                                              ? null
                                              : (_) => _setRotation(rotation),
                                        ),
                                      )
                                      .toList(),
                                ),
                                const SizedBox(height: 16),
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: const Color(0xFFD8DFEA),
                                    ),
                                  ),
                                  child: Text(
                                    _controller.setupMessage,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF374151),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  alignment: WrapAlignment.end,
                                  children: [
                                    OutlinedButton(
                                      onPressed: busy ? null : _checkConnection,
                                      child: const Text('Проверить соединение'),
                                    ),
                                    if (pending)
                                      OutlinedButton(
                                        onPressed: busy ? null : _resetFlow,
                                        child: const Text('Изменить настройки'),
                                      ),
                                    ElevatedButton(
                                      onPressed: busy
                                          ? null
                                          : pending
                                          ? _refreshStatus
                                          : _submitRequest,
                                      child: Text(
                                        pending
                                            ? 'Проверить статус'
                                            : 'Отправить заявку',
                                      ),
                                    ),
                                  ],
                                ),
                                if (busy) ...[
                                  const SizedBox(height: 16),
                                  const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ],
                                if (pending) ...[
                                  const SizedBox(height: 18),
                                  Text(
                                    'После подтверждения устройство автоматически начнет синхронизацию.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF5F6B84),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          _PinSetupCard(
                            controller: _pinController,
                            saved: _pinSaved,
                            onSave: _savePin,
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ),
            ),  // close SingleChildScrollView
          );    // close FocusTraversalGroup
          },    // close LayoutBuilder builder
        ),
      ),
    );
  }
}

class _PinSetupCard extends StatefulWidget {
  const _PinSetupCard({
    required this.controller,
    required this.saved,
    required this.onSave,
  });

  final TextEditingController controller;
  final bool saved;
  final VoidCallback onSave;

  @override
  State<_PinSetupCard> createState() => _PinSetupCardState();
}

class _PinSetupCardState extends State<_PinSetupCard> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFD8DFEA)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 20, color: Color(0xFF1F2533)),
              const SizedBox(width: 8),
              Text(
                'Сервисный PIN-код',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2533),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Защищает вход в редактор плейлиста на устройстве. Оставьте пустым, чтобы отключить защиту.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF5F6B84),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: widget.controller,
            obscureText: _obscure,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'PIN-код',
              hintText: 'Например: 1234',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: widget.onSave,
              icon: Icon(
                widget.saved ? Icons.check : Icons.save_outlined,
                size: 18,
              ),
              label: Text(widget.saved ? 'Сохранено' : 'Сохранить PIN'),
              style: FilledButton.styleFrom(
                backgroundColor: widget.saved
                    ? Colors.green.shade600
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: const Color(0xFF5F6B84),
          ),
        ),
        const SizedBox(height: 6),
        SelectableText(
          value,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: const Color(0xFF1F2533),
          ),
        ),
      ],
    );
  }
}

class _SectionBox extends StatelessWidget {
  const _SectionBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD8DFEA)),
      ),
      child: child,
    );
  }
}

class _DisplayCard extends StatelessWidget {
  const _DisplayCard({
    required this.index,
    required this.display,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final DeviceDisplayProfile display;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? const Color(0xFF3167E3)
        : const Color(0xFFD8DFEA);
    final background = selected ? const Color(0xFFF4F8FF) : Colors.white;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        width: 180,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF3167E3)
                    : const Color(0xFFE8EEF8),
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  color: selected ? Colors.white : const Color(0xFF1F2533),
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              display.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2533),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              display.resolutionLabel,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF5F6B84)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (display.isPrimary) const _DisplayBadge('Primary'),
                if (display.isCurrent) const _DisplayBadge('Current'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DisplayBadge extends StatelessWidget {
  const _DisplayBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEF8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF4A5874),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
