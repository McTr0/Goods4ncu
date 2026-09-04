import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../brand/app_brand.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';

class LoginPage extends StatefulWidget {
  final AuthService? authService;

  const LoginPage({super.key, this.authService});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  late final AuthService _authService;
  bool _isLogin = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? context.read<AuthService>();
  }

  Future<void> _submit() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      final username = _usernameController.text.trim();
      final password = _passwordController.text;

      if (username.isEmpty || password.isEmpty) {
        throw Exception(l.loginError);
      }

      if (!_isLogin && password != _confirmPasswordController.text) {
        throw Exception(l.registerError);
      }
      final email = _emailController.text.trim();
      if (!_isLogin && email.isEmpty) {
        throw Exception(l.campusEmailRequired);
      }

      String token;
      if (_isLogin) {
        token = await _authService.login(username, password);
      } else {
        token = await _authService.register(username, password, email: email);
      }

      if (token.isNotEmpty) {
        if (mounted) {
          context.go('/');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${l.error}: ${e.toString()}')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppTheme.surface, Color(0xFFFFE6C7), AppTheme.mint],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 860;
              return SingleChildScrollView(
                padding: const EdgeInsets.all(AppTheme.sp24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: wide
                          ? Row(
                              children: [
                                const Expanded(child: _LoginBrandPanel()),
                                const SizedBox(width: AppTheme.sp32),
                                SizedBox(width: 430, child: _buildAuthCard(l)),
                              ],
                            )
                          : Column(
                              children: [
                                const _LoginBrandPanel(compact: true),
                                const SizedBox(height: AppTheme.sp24),
                                _buildAuthCard(l),
                              ],
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAuthCard(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppTheme.radius2xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.86)),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _AuthModeToggle(
            isLogin: _isLogin,
            loginLabel: l.login,
            registerLabel: l.register,
            onChanged: (loginMode) {
              setState(() => _isLogin = loginMode);
            },
          ),
          const SizedBox(height: AppTheme.sp24),
          Text(
            _isLogin ? '欢迎回来' : '创建你的校园账号',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: AppTheme.sp8),
          Text(
            _isLogin ? '继续发现附近同学的好物。' : '发布、收藏、议价，从一个账号开始。',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTheme.sp24),
          TextField(
            controller: _usernameController,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l.username,
              prefixIcon: const Icon(Icons.person_outline_rounded),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: _isLogin
                ? const SizedBox.shrink()
                : Padding(
                    key: const ValueKey('campus-email'),
                    padding: const EdgeInsets.only(top: AppTheme.sp16),
                    child: TextField(
                      controller: _emailController,
                      autofillHints: const [AutofillHints.email],
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l.campusEmail,
                        hintText: l.campusEmailHint,
                        prefixIcon: const Icon(Icons.school_outlined),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: AppTheme.sp16),
          TextField(
            controller: _passwordController,
            autofillHints: const [AutofillHints.password],
            textInputAction: _isLogin
                ? TextInputAction.done
                : TextInputAction.next,
            onSubmitted: (_) {
              if (_isLogin && !_isLoading) {
                _submit();
              }
            },
            decoration: InputDecoration(
              labelText: l.password,
              prefixIcon: const Icon(Icons.lock_outline_rounded),
            ),
            obscureText: true,
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: _isLogin
                ? const SizedBox.shrink()
                : Padding(
                    key: const ValueKey('confirm-password'),
                    padding: const EdgeInsets.only(top: AppTheme.sp16),
                    child: TextField(
                      controller: _confirmPasswordController,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!_isLoading) {
                          _submit();
                        }
                      },
                      decoration: InputDecoration(
                        labelText: l.confirmPassword,
                        prefixIcon: const Icon(Icons.verified_user_outlined),
                      ),
                      obscureText: true,
                    ),
                  ),
          ),
          const SizedBox(height: AppTheme.sp24),
          SizedBox(
            height: 54,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _submit,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _isLoading
                    ? const SizedBox(
                        key: ValueKey('loading'),
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        _isLogin ? l.login : l.register,
                        key: const ValueKey('label'),
                      ),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.sp16),
          TextButton(
            onPressed: _isLoading
                ? null
                : () {
                    setState(() => _isLogin = !_isLogin);
                  },
            child: Text(_isLogin ? '还没有账号？${l.register}' : '已有账号？${l.login}'),
          ),
        ],
      ),
    );
  }
}

class _LoginBrandPanel extends StatelessWidget {
  final bool compact;

  const _LoginBrandPanel({this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? AppTheme.sp20 : AppTheme.sp32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radius2xl),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryDark, AppTheme.primary, Color(0xFF2A9D8F)],
        ),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Stack(
        children: [
          Positioned(
            right: compact ? -36 : -18,
            top: compact ? -42 : -18,
            child: _DecorCircle(size: compact ? 116 : 180),
          ),
          Positioned(
            left: -36,
            bottom: -44,
            child: _DecorCircle(
              size: compact ? 92 : 136,
              color: AppTheme.accentSoft,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compact ? 54 : 68,
                height: compact ? 54 : 68,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.asset(AppBrand.logoAsset, fit: BoxFit.cover),
                ),
              ),
              SizedBox(height: compact ? AppTheme.sp20 : AppTheme.sp32),
              Text(
                AppBrand.englishName,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 34 : 48,
                  height: 0.96,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.4,
                ),
              ),
              const SizedBox(height: AppTheme.sp14),
              Text(
                '给南昌大学同学的 AI 二手集市',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: compact ? 15 : 18,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: AppTheme.sp32),
                const Wrap(
                  spacing: AppTheme.sp12,
                  runSpacing: AppTheme.sp12,
                  children: [
                    _BrandPill(icon: Icons.bolt_rounded, label: 'AI 协助'),
                    _BrandPill(icon: Icons.handshake_rounded, label: '安全议价'),
                    _BrandPill(icon: Icons.location_on_rounded, label: '校园场景'),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DecorCircle extends StatelessWidget {
  final double size;
  final Color color;

  const _DecorCircle({required this.size, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _BrandPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _BrandPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.sp12,
        vertical: AppTheme.sp8,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: AppTheme.sp6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthModeToggle extends StatelessWidget {
  final bool isLogin;
  final String loginLabel;
  final String registerLabel;
  final ValueChanged<bool> onChanged;

  const _AuthModeToggle({
    required this.isLogin,
    required this.loginLabel,
    required this.registerLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppTheme.sand,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeSegment(
              label: loginLabel,
              selected: isLogin,
              onTap: () => onChanged(true),
            ),
          ),
          Expanded(
            child: _ModeSegment(
              label: registerLabel,
              selected: !isLogin,
              onTap: () => onChanged(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        boxShadow: selected ? AppTheme.softShadow : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.sp12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? AppTheme.primaryDark : AppTheme.textSecondary,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}
