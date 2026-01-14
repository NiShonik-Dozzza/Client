// lib/main.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'controllers/playlist_controller.dart';
import 'views/editor_screen.dart';
import 'views/player_screen.dart';
import 'package:media_kit/media_kit.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // ← обязательно для media_kit
  MediaKit.ensureInitialized();        // ← основной вызов инициализации
  Get.put(PlaylistController());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Media Player',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: ElevatedButton(
              onPressed: () => Get.to(PlayerScreen()),
              child: const Text('ЗАПУСТИТЬ ПЛЕЕР'),
            ),
          ),
          Expanded(
            child: ElevatedButton(
              onPressed: () => Get.to(EditorScreen()),
              child: const Text('РЕДАКТОР ПЛЕЙЛИСТА'),
            ),
          ),
        ],
      ),
    );
  }
}
// // main.dart
// import 'package:flutter/material.dart';
// import 'package:get/get.dart';
//
// void main() {
//   runApp(const MyApp());
// }
//
// class MyApp extends StatelessWidget {
//   const MyApp({super.key});
//
//   @override
//   Widget build(BuildContext context) {
//     return GetMaterialApp( // ← Обрати внимание: GetMaterialApp вместо MaterialApp!
//       title: 'GetX Counter',
//       home: CounterView(),
//     );
//   }
// }
//
// class CounterView extends StatelessWidget {
//   final CounterController controller = Get.put(CounterController());
//
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//
//       //appBar: AppBar(title: const Text('GetX Counter')),
//
//       body: Center(
//         child: Obx(() => Text(
//           '${controller.count}', // Автоматически обновится при изменении count
//           style: const TextStyle(fontSize: 48),
//         )),
//       ),
//
//       // Кнопки с низу ВРЕММЕННО
//
//       floatingActionButton: Row(
//         mainAxisAlignment: MainAxisAlignment.center,
//         children: [
//           FloatingActionButton(
//             onPressed: controller.decrement,
//             child: const Icon(Icons.remove),
//           ),
//           const SizedBox(width: 20),
//           FloatingActionButton(
//             onPressed: controller.increment,
//             child: const Icon(Icons.add),
//           ),
//         ],
//       ),
//     );
//   }
// }
//
// class CounterController extends GetxController {
//   var count = 0.obs; // .obs — делает переменную "наблюдаемой"
//
//   void increment() => count++;
//   void decrement() => count--;
// }