import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/design.dart';
import '../services/friendly_error.dart';
import '../services/travel_repository.dart';
import '../widgets/brand/lakbay_wordmark.dart';

/// Full-screen traveler authentication flow supporting Account Creation
/// (`Create your account`) and Sign In (`Welcome back`), including Google Sign-In,
/// email/password + confirmation validation, password visibility toggles, and
/// interactive Terms / Privacy dialogs.
class AuthScreen extends StatefulWidget {
  final TravelRepository repo;
  final bool initialRegisterMode;
  final VoidCallback? onAuthenticated;

  const AuthScreen({
    super.key,
    required this.repo,
    this.initialRegisterMode = true,
    this.onAuthenticated,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _fullNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  late bool _isRegister;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  bool _googleBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _isRegister = widget.initialRegisterMode;
    final savedEmail = widget.repo.profile.email.trim();
    if (widget.repo.isSignedIn && savedEmail.isNotEmpty) {
      _emailCtrl.text = savedEmail;
    }
  }

  @override
  void dispose() {
    _fullNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitEmailAuth() async {
    if (_busy || _googleBusy) return;
    final fullName = _fullNameCtrl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirmPassword = _confirmPasswordCtrl.text;

    if (_isRegister &&
        (fullName.length < 2 || fullName.toLowerCase() == 'lakbay traveler')) {
      setState(
        () => _error = 'Please enter your full name (at least 2 characters).',
      );
      return;
    }

    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters long.');
      return;
    }
    if (_isRegister && password != confirmPassword) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (widget.repo.apiCatalog.isConfigured) {
        if (_isRegister) {
          await widget.repo.registerWithBackend(
            fullName: fullName,
            email: email,
            password: password,
            confirmPassword: confirmPassword,
          );
        } else {
          await widget.repo.signInWithBackend(email: email, password: password);
        }
      } else {
        setState(() {
          _busy = false;
          _error = 'Connect LAKBAY_API_BASE_URL to sign in or create your Lakbay+ account.';
        });
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
      _completeAuth();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _submitGoogleAuth() async {
    if (_busy || _googleBusy) return;
    setState(() {
      _googleBusy = true;
      _error = null;
    });
    try {
      await widget.repo.signInWithGoogleBackend();
      if (!mounted) return;
      setState(() => _googleBusy = false);
      _completeAuth();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _googleBusy = false;
        _error = friendlyError(e);
      });
    }
  }

  void _completeAuth() {
    if (widget.onAuthenticated != null) {
      widget.onAuthenticated!();
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  void _showLegalDialog(BuildContext context, String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(
            fontFamily: LkType.displayFamily,
            fontWeight: FontWeight.w800,
            color: LkColors.text,
          ),
        ),
        content: Text(
          body,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: LkColors.muted,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy || _googleBusy;
    final photo = widget.repo.currentBackdrop.localAssetPath;
    final canPop = Navigator.of(context).canPop();

    return Scaffold(
      // The sheet's color, so it reads as one sheet down to the bottom edge.
      backgroundColor: LkColors.s1,
      body: Stack(
        children: [
          // Region XI photo behind the top of the sheet.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: MediaQuery.sizeOf(context).height * 0.36,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  photo,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LkColors.surfaceGradient,
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(gradient: LkColors.heroScrim),
                ),
              ],
            ),
          ),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      LkSpace.l,
                      LkSpace.s,
                      LkSpace.l,
                      0,
                    ),
                    child: Row(
                      children: [
                        if (canPop)
                          LkIconButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: 'Back',
                            style: LkIconButtonStyle.glass,
                            onPressed: busy
                                ? null
                                : () => Navigator.of(context).maybePop(false),
                          ),
                        const Spacer(),
                        const LakbayWordmark(fontSize: 24),
                        const Spacer(),
                        if (canPop) const SizedBox(width: kLkMinTarget),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.14,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: LkColors.s1,
                      borderRadius: LkRadius.sheetTop,
                      border: Border(top: BorderSide(color: LkColors.stroke)),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      LkSpace.xxl,
                      LkSpace.xxl,
                      LkSpace.xxl,
                      LkSpace.l,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: _buildForm(context, busy),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            _isRegister ? 'Create your account' : 'Sign in to Lakbay+',
            style: LkType.h2,
          ),
        ),
        const SizedBox(height: LkSpace.s),
        Text(
          _isRegister
              ? 'Save your plans, trips and memories to your account.'
              : 'Pick up your saved Davao Region trips, bucket list and '
                    'memories.',
          style: LkType.body.copyWith(color: LkColors.muted),
        ),
        const SizedBox(height: LkSpace.xxl),
        SizedBox(
          height: 52,
          child: OutlinedButton(
            onPressed: busy ? null : _submitGoogleAuth,
            style: OutlinedButton.styleFrom(
              backgroundColor: LkColors.s2,
              foregroundColor: LkColors.text,
              side: const BorderSide(color: LkColors.strokeStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(LkRadius.sm),
              ),
            ),
            child: _googleBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const _GoogleGMark(size: 20),
                      const SizedBox(width: LkSpace.m),
                      Text(
                        'Continue with Google',
                        style: LkType.button.copyWith(fontSize: 15),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: LkSpace.xl),
        Row(
          children: [
            const Expanded(child: Divider(color: LkColors.stroke)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LkSpace.m),
              child: Text('or with email', style: LkType.caption),
            ),
            const Expanded(child: Divider(color: LkColors.stroke)),
          ],
        ),
        const SizedBox(height: LkSpace.xl),
        if (_isRegister) ...[
          _AuthTextField(
            controller: _fullNameCtrl,
            label: 'Full name',
            keyboardType: TextInputType.name,
            autofillHints: const [AutofillHints.name],
          ),
          const SizedBox(height: LkSpace.m),
        ],
        _AuthTextField(
          controller: _emailCtrl,
          label: 'Email',
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: LkSpace.m),
        _AuthTextField(
          controller: _passwordCtrl,
          label: 'Password',
          obscureText: _obscurePassword,
          autofillHints: [
            _isRegister ? AutofillHints.newPassword : AutofillHints.password,
          ],
          suffixIcon: IconButton(
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: LkColors.muted,
            ),
            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
          ),
        ),
        if (_isRegister) ...[
          const SizedBox(height: LkSpace.m),
          _AuthTextField(
            controller: _confirmPasswordCtrl,
            label: 'Confirm password',
            obscureText: _obscureConfirm,
            autofillHints: const [AutofillHints.newPassword],
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
              icon: Icon(
                _obscureConfirm
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: LkColors.muted,
              ),
              tooltip: _obscureConfirm
                  ? 'Show confirm password'
                  : 'Hide confirm password',
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: LkSpace.m),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: LkSpace.m,
                vertical: LkSpace.s,
              ),
              decoration: BoxDecoration(
                color: LkColors.danger.withValues(alpha: 0.12),
                borderRadius: LkRadius.smAll,
                border: Border.all(
                  color: LkColors.danger.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: LkColors.danger,
                    ),
                  ),
                  const SizedBox(width: LkSpace.s),
                  Expanded(
                    child: Text(
                      _error!,
                      style: LkType.label.copyWith(color: LkColors.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: LkSpace.xxl),
        LkButton(
          label: _isRegister ? 'Create account' : 'Sign in',
          size: LkButtonSize.large,
          expand: true,
          loading: _busy,
          onPressed: busy ? null : _submitEmailAuth,
        ),
        const SizedBox(height: LkSpace.s),
        Center(
          child: TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    _isRegister = !_isRegister;
                    _error = null;
                  }),
            child: Text.rich(
              TextSpan(
                text: _isRegister
                    ? 'Already have an account? '
                    : 'New to Lakbay+? ',
                style: LkType.body.copyWith(color: LkColors.muted),
                children: [
                  TextSpan(
                    text: _isRegister ? 'Sign in' : 'Create account',
                    style: LkType.bodyStrong.copyWith(color: LkColors.mango),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: LkSpace.l),
        Text.rich(
          TextSpan(
            style: LkType.caption,
            children: [
              const TextSpan(text: 'By continuing you agree to the '),
              TextSpan(
                text: 'Terms',
                style: const TextStyle(
                  decoration: TextDecoration.underline,
                  color: LkColors.text,
                ),
                recognizer: TapGestureRecognizer()
                  ..onTap = () => _showLegalDialog(
                    context,
                    'Terms of Service',
                    'Lakbay+ plans trips across the Davao Region (Region XI) with AI. Prices and schedules come from local rates kept by the Lakbay+ team and are estimates, so confirm with the operator before you travel.',
                  ),
              ),
              const TextSpan(text: ' and '),
              TextSpan(
                text: 'Privacy Policy.',
                style: const TextStyle(
                  decoration: TextDecoration.underline,
                  color: LkColors.text,
                ),
                recognizer: TapGestureRecognizer()
                  ..onTap = () => _showLegalDialog(
                    context,
                    'Privacy Policy',
                    'Your account credentials, saved trips, and optional GPS location preferences are stored securely on your device and synced only to your Lakbay+ backend account when signed in.',
                  ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TextInputType keyboardType;
  final bool obscureText;
  final Widget? suffixIcon;
  final Iterable<String>? autofillHints;

  const _AuthTextField({
    required this.controller,
    required this.label,
    this.keyboardType = TextInputType.text,
    this.obscureText = false,
    this.suffixIcon,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      autofillHints: autofillHints,
      style: LkType.bodyLarge,
      decoration: InputDecoration(labelText: label, suffixIcon: suffixIcon),
    );
  }
}

class _GoogleGMark extends StatelessWidget {
  final double size;
  const _GoogleGMark({this.size = 22});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.19;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Blue top-right + horizontal bar
    paint.color = const Color(0xFF4285F4);
    canvas.drawArc(rect, -0.25, 1.15, false, paint);
    canvas.drawLine(
      Offset(size.width * 0.52, size.height * 0.50),
      Offset(size.width * 0.92, size.height * 0.50),
      paint,
    );

    // Green bottom-right/left
    paint.color = const Color(0xFF34A853);
    canvas.drawArc(rect, 0.88, 1.55, false, paint);

    // Yellow left
    paint.color = const Color(0xFFFBBC05);
    canvas.drawArc(rect, 2.42, 1.15, false, paint);

    // Red top
    paint.color = const Color(0xFFEA4335);
    canvas.drawArc(rect, 3.55, 2.05, false, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
