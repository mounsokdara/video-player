import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'crash.dart';
import 'home.dart';
import 'library.dart';
import 'models.dart';
import 'settings.dart';
import 'theme.dart';

export 'settings.dart';

final appSettings = AppSettings();
final library = LibraryService(appSettings);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    CrashLog.record('FLUTTER', details.exceptionAsString(), details.stack);
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    CrashLog.record('PLATFORM', '$error', stack);
    return true;
  };
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await appSettings.load();
  await CrashLog.install();
  runApp(const VideoPlayerApp());
}

class VideoPlayerApp extends StatefulWidget {
  const VideoPlayerApp({super.key});

  @override
  State<VideoPlayerApp> createState() => _VideoPlayerAppState();
}

class _VideoPlayerAppState extends State<VideoPlayerApp> {
  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (light, dark) {
        final mode = appSettings.themeMode;
        return MaterialApp(
          navigatorKey: appNavigator,
          title: 'Video Player',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            brightness: Brightness.light,
            settings: appSettings,
            dynamicScheme: light,
          ),
          darkTheme: AppTheme.build(
            brightness: Brightness.dark,
            settings: appSettings,
            dynamicScheme: dark,
          ),
          themeMode: switch (mode) {
            ThemeModePref.system => ThemeMode.system,
            ThemeModePref.light => ThemeMode.light,
            ThemeModePref.dark => ThemeMode.dark,
          },
          builder: (context, child) {
            final scale = appSettings.uiScale.clamp(0.85, 1.35);
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                boldText: appSettings.boldText,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: HomeShell(
            onSettingsChanged: () {
              setState(() {});
              appSettings.save();
            },
          ),
        );
      },
    );
  }
}
