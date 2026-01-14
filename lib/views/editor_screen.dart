// lib/views/editor_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/playlist_controller.dart';
import '../models/playlist_item.dart';

class EditorScreen extends StatelessWidget {
  final _formKey = GlobalKey<FormState>();
  final _filenameController = TextEditingController();
  final _startDateController = TextEditingController();
  final _loopController = TextEditingController(text: 'true');

  EditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<PlaylistController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Редактор плейлиста'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(), // ← возврат назад
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Список элементов
            Expanded(
              child: Obx(() {
                if (controller.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView.builder(
                  itemCount: controller.items.length,
                  itemBuilder: (context, i) {
                    final item = controller.items[i];
                    return Card(
                      child: ListTile(
                        title: Text(item.filename),
                        subtitle: Text(
                          'Начало: ${item.startDate.toLocal().toString().split('.').first}\n'
                              'Повтор: ${item.loop ? "Да" : "Нет"}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => controller.removeItem(i),
                        ),
                      ),
                    );
                  },
                );
              }),
            ),
            // Форма добавления
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _filenameController,
                    decoration: const InputDecoration(labelText: 'Имя файла (из assets/media/)'),
                    validator: (v) => v!.isEmpty ? 'Обязательно' : null,
                  ),
                  TextFormField(
                    controller: _startDateController,
                    decoration: const InputDecoration(labelText: 'Дата начала (ГГГГ-ММ-ДД чч:мм)'),
                    validator: (v) {
                      if (v!.isEmpty) return 'Обязательно';
                      try {
                        DateTime.parse(v);
                        return null;
                      } catch (e) {
                        return 'Неверный формат';
                      }
                    },
                  ),
                  Row(
                    children: [
                      const Text('Повторять? '),
                      Switch(
                        value: _loopController.text == 'true',
                        onChanged: (v) => _loopController.text = v.toString(),
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: () {
                      if (_formKey.currentState!.validate()) {
                        final item = PlaylistItem(
                          filename: _filenameController.text.trim(),
                          startDate: DateTime.parse(_startDateController.text.trim()),
                          loop: _loopController.text == 'true',
                        );
                        controller.addItem(item);
                        _filenameController.clear();
                        _startDateController.clear();
                        _loopController.text = 'true';
                      }
                    },
                    child: const Text('Добавить в плейлист'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}