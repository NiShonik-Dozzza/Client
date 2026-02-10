import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

import 'controllers/playlist_controller.dart';
import 'views/player_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Полный экран (киоск)
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // ✅ Регистрируем контроллер ДО runApp
  Get.put(PlaylistController(), permanent: true);

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return const GetMaterialApp(
      debugShowCheckedModeBanner: false,
      home: PlayerScreen(),
    );
  }
}
