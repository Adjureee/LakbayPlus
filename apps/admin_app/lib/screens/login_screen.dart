import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/session_manager.dart';
import '../core/theme/app_theme.dart';
import '../widgets/lakbay_wordmark.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _api = ApiService();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.login(_email.text.trim(), _password.text);
      if (result['role'] != 'admin') {
        throw const ApiException(
          'Use an administrator account to access this workspace.',
        );
      }
      await SessionManager.instance.saveSession(
        token: result['access_token'].toString(),
        refreshToken: result['refresh_token']?.toString(),
        name: (result['full_name'] ?? '').toString(),
        email: result['email'].toString(),
        role: result['role'].toString(),
        userId: result['user_id'].toString(),
      );
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/dashboard', (_) => false);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Always the dark v8 look, like the traveler app's Welcome, whatever the
    // workspace theme is.
    return Theme(
      data: AppTheme.darkTheme,
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          final form = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!wide) ...[
                      const LakbayWordmark(fontSize: 30),
                      const SizedBox(height: 32),
                    ],
                    Semantics(
                      header: true,
                      child: Text(
                        'Welcome back',
                        style: theme.textTheme.headlineMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in to the Lakbay+ admin workspace.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _email,
                      enabled: !_busy,
                      autofillHints: const [
                        AutofillHints.username,
                        AutofillHints.email,
                      ],
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (value) =>
                          value == null ||
                              !RegExp(
                                r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                              ).hasMatch(value.trim())
                          ? 'Enter a valid email address.'
                          : null,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _signIn(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Enter your password.'
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 20),
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.error.withValues(
                                alpha: 0.45,
                              ),
                            ),
                          ),
                          child: Text(_error!),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton(
                        onPressed: _busy ? null : _signIn,
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.mangoInk,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Administrator access only',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          );

          final panel = Container(
            color: theme.cardColor,
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(wide ? 56 : 24),
                child: form,
              ),
            ),
          );

          if (!wide) {
            return Column(
              children: [
                const SizedBox(height: 180, child: _PhotoPanel(compact: true)),
                Expanded(child: panel),
              ],
            );
          }
          return Row(
            children: [
              const Expanded(flex: 6, child: _PhotoPanel()),
              Expanded(flex: 5, child: panel),
            ],
          );
        },
      ),
    );
  }
}

/// A Region XI photo with the brand and a plain description of the
/// workspace, as on the traveler app's Welcome.
class _PhotoPanel extends StatelessWidget {
  const _PhotoPanel({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/destinations/jacks_ridge.jpg',
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) =>
              const ColoredBox(color: AppTheme.darkSurface),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xD9021114), Color(0x40021114), Color(0xF2021114)],
              stops: [0, 0.4, 1],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.all(compact ? 24 : 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LakbayWordmark(fontSize: compact ? 26 : 30, color: Colors.white),
              if (!compact) ...[
                const Spacer(),
                Text(
                  'Region XI travel data,\nkept current.',
                  style: AppTheme.display(size: 44, color: Colors.white),
                ),
                const SizedBox(height: 16),
                Text(
                  'Destinations, sea links and market rates that Lakbay AI '
                  'plans from, plus the people, trips and reviews behind '
                  'them.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                  ),
                ),
                const SizedBox(height: 24),
                const Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Chip(label: Text('Destinations')),
                    Chip(label: Text('Sea links')),
                    Chip(label: Text('Market rates')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
