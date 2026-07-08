import 'package:easyi18n/easyi18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Replace with your easyi18n project id.
const String kProjectId = 'demo';

/// `--dart-define=USE_EMULATOR=true` points the SDK at the local backend
/// delivery origin (`tool/backend-up.sh`); otherwise it uses the default origin.
const bool kUseEmulator = bool.fromEnvironment('USE_EMULATOR');

/// A `capture`-scope dev token enables auto-capture in debug:
/// `--dart-define=EASYI18N_CAPTURE_TOKEN=eik_…`. Never ship it in release.
const String kCaptureToken = String.fromEnvironment('EASYI18N_CAPTURE_TOKEN');

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Locale _locale = const Locale('en');

  @override
  Widget build(BuildContext context) {
    // Easyi18nScope wraps MaterialApp - the only required argument is the
    // project id. Baked floors live in assets/easyi18n/{locale}.json; the SDK
    // hot-updates them from the manifest with no extra code.
    return Easyi18nScope(
      projectId: kProjectId,
      baseUrl: kUseEmulator ? Uri.parse('http://localhost:8080') : null,
      supportedLocales: const ['en', 'es'],
      captureToken: kCaptureToken.isEmpty ? null : kCaptureToken,
      child: MaterialApp(
        locale: _locale,
        supportedLocales: const [Locale('en'), Locale('es')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: _HomePage(
          locale: _locale,
          onToggleLocale: () => setState(() {
            _locale = _locale.languageCode == 'en'
                ? const Locale('es')
                : const Locale('en');
          }),
        ),
      ),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({required this.locale, required this.onToggleLocale});
  final Locale locale;
  final VoidCallback onToggleLocale;

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  int _count = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Welcome to easyi18n'))),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.tr('Hello {name}', args: {'name': 'Leo'})),
            const SizedBox(height: 12),
            Text(
              context.tr(
                '{count, plural, one{You have {count} message} '
                'other{You have {count} messages}}',
                args: {'count': _count},
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => setState(() => _count++),
              child: const Text('+1'),
            ),
            TextButton(
              onPressed: widget.onToggleLocale,
              child: Text('Locale: ${widget.locale.languageCode}'),
            ),
          ],
        ),
      ),
    );
  }
}
