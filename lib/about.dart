import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'android_bridge.dart';
import 'crash.dart';
import 'developer_log.dart';
import 'settings.dart';

class AboutInfo {
  AboutInfo._();
  static const name = 'Video Player';
  static const author = 'Moun Sokdara';
  static const displayVersion = '1.0.0_BETA';
  static const legalese = 'Local-only Android player. Material 3.';
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  PackageInfo? _info;
  int _taps = 0;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((v) {
      if (mounted) setState(() => _info = v);
    });
  }

  void _onVersionTap() {
    final now = DateTime.now();
    if (now.difference(_lastTap) > const Duration(seconds: 2)) _taps = 0;
    _lastTap = now;
    _taps += 1;
    if (appSettings.developerEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Developer options are on')),
      );
      return;
    }
    final left = 10 - _taps;
    if (left > 0 && left <= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$left tap${left == 1 ? '' : 's'} away from developer options')),
      );
    }
    if (_taps >= 10) {
      _taps = 0;
      appSettings.developerEnabled = true;
      unawaited(appSettings.save());
      unawaited(HapticFeedback.mediumImpact());
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Developer options enabled')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final version = _info == null
        ? AboutInfo.displayVersion
        : '${_info!.version} (${_info!.buildNumber})';
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
            child: const Icon(Icons.play_circle_fill, size: 40),
          ),
          const SizedBox(height: 16),
          Text(AboutInfo.name, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(AboutInfo.legalese, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Created by'),
            subtitle: const Text(AboutInfo.author),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tag),
            title: const Text('Build version'),
            subtitle: Text('$version · ${AboutInfo.displayVersion}'),
            onTap: _onVersionTap,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.balance_outlined),
            title: const Text('Open source licenses'),
            subtitle: const Text('Flutter, Dart, ExoPlayer, AndroidX, Kotlin'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: AboutInfo.name,
              applicationVersion: version,
              applicationLegalese: '${AboutInfo.legalese}\nCreated by ${AboutInfo.author}.',
            ),
          ),
          if (appSettings.developerEnabled) ...[
            const Divider(height: 32),
            Text('Developer options', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Log debug'),
              subtitle: const Text('Write extra player and native traces to the console'),
              value: appSettings.debugLog,
              onChanged: (v) {
                setState(() => appSettings.debugLog = v);
                unawaited(appSettings.save());
                DeveloperLog.append('debugLog=$v');
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.terminal),
              title: const Text('Console'),
              subtitle: const Text('Debug log and crash breadcrumbs'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DeveloperConsolePage()),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class DeveloperConsolePage extends StatefulWidget {
  const DeveloperConsolePage({super.key});

  @override
  State<DeveloperConsolePage> createState() => _DeveloperConsolePageState();
}

class _DeveloperConsolePageState extends State<DeveloperConsolePage> {
  String _text() {
    final body = StringBuffer()
      ..writeln('=== debug ===')
      ..writeln(DeveloperLog.text)
      ..writeln()
      ..writeln('=== crash ===')
      ..writeln(CrashLog.text);
    return body.toString();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Console'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              }
            },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Clear debug',
            onPressed: () {
              DeveloperLog.clear();
              setState(() {});
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35),
        ),
      ),
    );
  }
}
