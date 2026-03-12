import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/playlist_controller.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _serverController;
  late final TextEditingController _nameController;

  PlaylistController get _controller => Get.find<PlaylistController>();

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: _controller.serverAddress);
    _nameController = TextEditingController(
      text: _controller.deviceDisplayName,
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _nameController.dispose();
    super.dispose();
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
    if (mounted) {
      setState(() {
        _serverController.text = _controller.serverAddress;
        _nameController.text = _controller.deviceDisplayName;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Obx(() {
                final pending = _controller.isPendingApproval;
                final busy = _controller.setupBusy;
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
                    const SizedBox(height: 10),
                    Text(
                      'Клиент сам инициирует регистрацию. После отправки заявки администратор подтверждает устройство в панели управления.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF5F6B84),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: cardColor,
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
                                  'Например: 192.168.1.50:443 или http://192.168.1.50:443',
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
                            const Center(child: CircularProgressIndicator()),
                          ],
                          if (pending) ...[
                            const SizedBox(height: 18),
                            Text(
                              'После подтверждения клиент автоматически перейдёт к синхронизации и загрузке контента.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF5F6B84),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
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
