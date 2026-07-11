import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'l10n/app_localizations.dart';
import 'brand/app_brand.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'services/locale_service.dart';
import 'providers/service_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleService.init();
  ErrorWidget.builder = (details) => _FallbackErrorWidget(details: details);
  runApp(const Goods4ncuApp());
}

class _FallbackErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FallbackErrorWidget({required this.details});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                '出现了一些问题',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString(),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Goods4ncuApp extends StatefulWidget {
  const Goods4ncuApp({super.key});

  @override
  State<Goods4ncuApp> createState() => _Goods4ncuAppState();
}

class _Goods4ncuAppState extends State<Goods4ncuApp> {
  final LocaleNotifier _localeNotifier = LocaleNotifier();

  @override
  void dispose() {
    _localeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LocaleProvider(
      notifier: _localeNotifier,
      child: MultiProvider(
        providers: serviceProviders,
        child: ListenableBuilder(
          listenable: _localeNotifier,
          builder: (context, _) {
            return MaterialApp.router(
              title: AppBrand.englishName,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ThemeMode.system,
              locale: _localeNotifier.locale,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: const [Locale('en'), Locale('zh')],
              routerConfig: appRouter,
              debugShowCheckedModeBanner: false,
            );
          },
        ),
      ),
    );
  }
}
