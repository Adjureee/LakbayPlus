import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

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
    final fullName =
        _fullNameCtrl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirmPassword = _confirmPasswordCtrl.text;

    if (_isRegister &&
        (fullName.length < 2 ||
            fullName.toLowerCase() == 'lakbay traveler')) {
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
      setState(
        () => _error = 'Password must be at least 8 characters long.',
      );
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
          await widget.repo.signInWithBackend(
            email: email,
            password: password,
          );
        }
      } else {
        setState(() {
          _busy = false;
          _error =
              'Connect LAKBAY_API_BASE_URL to sign in or create your Lakbay+ account.';
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
        _error = e.toString();
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
        _error = e.toString();
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
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w800,
            color: LakbayColors.tealDeep,
          ),
        ),
        content: Text(
          body,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: LakbayColors.textSecondary,
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
    const surfaceBg = Color(0xFFFAF7F4);
    const pillLavender = Color(0xFFC5B3F9);
    const pillLavenderText = Color(0xFF1E1B24);
    const fieldBorder = Color(0xFFDED9D3);

    return Scaffold(
      backgroundColor: surfaceBg,
      body: SafeArea(
        child: Column(
          children: [
            if (Navigator.of(context).canPop())
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: _busy || _googleBusy
                      ? null
                      : () => Navigator.of(context).maybePop(false),
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 20,
                    color: LakbayColors.tealDeep,
                  ),
                  tooltip: 'Back',
                ),
              )
            else
              const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _isRegister
                              ? 'Create your account'
                              : 'Sign in to Lakbay+',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            color: Color(0xFF1F1629),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _isRegister
                              ? 'Keep your plan, and give your travel expert\na way to reach you.'
                              : 'Restore your saved Davao Region trips,\nbucket list, and memories.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            color: Color(0xFF6B6570),
                          ),
                        ),
                        const SizedBox(height: 28),

                        // Continue with Google outlined pill
                        SizedBox(
                          height: 56,
                          child: OutlinedButton(
                            onPressed:
                                _busy || _googleBusy ? null : _submitGoogleAuth,
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF1F1629),
                              side: const BorderSide(color: fieldBorder),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(32),
                              ),
                            ),
                            child: _googleBusy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                    ),
                                  )
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _GoogleGMark(size: 22),
                                      SizedBox(width: 14),
                                      Text(
                                        'Continue with Google',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF1F1629),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),

                        const SizedBox(height: 22),
                        const Row(
                          children: [
                            Expanded(child: Divider(color: fieldBorder)),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 14),
                              child: Text(
                                'or',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1F1629),
                                ),
                              ),
                            ),
                            Expanded(child: Divider(color: fieldBorder)),
                          ],
                        ),
                        const SizedBox(height: 22),

                        if (_isRegister) ...[
                          _AuthTextField(
                            controller: _fullNameCtrl,
                            hintText: 'Full name',
                            keyboardType: TextInputType.name,
                            borderColor: fieldBorder,
                          ),
                          const SizedBox(height: 14),
                        ],
                        // Email input
                        _AuthTextField(
                          controller: _emailCtrl,
                          hintText: 'Email',
                          keyboardType: TextInputType.emailAddress,
                          borderColor: fieldBorder,
                        ),
                        const SizedBox(height: 14),

                        // Password input with eye toggle
                        _AuthTextField(
                          controller: _passwordCtrl,
                          hintText: 'Password',
                          obscureText: _obscurePassword,
                          borderColor: fieldBorder,
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: const Color(0xFF3E3A45),
                              size: 22,
                            ),
                            tooltip: _obscurePassword
                                ? 'Show password'
                                : 'Hide password',
                          ),
                        ),

                        if (_isRegister) ...[
                          const SizedBox(height: 14),
                          _AuthTextField(
                            controller: _confirmPasswordCtrl,
                            hintText: 'Confirm password',
                            obscureText: _obscureConfirm,
                            borderColor: fieldBorder,
                            suffixIcon: IconButton(
                              onPressed: () => setState(
                                () => _obscureConfirm = !_obscureConfirm,
                              ),
                              icon: Icon(
                                _obscureConfirm
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: const Color(0xFF3E3A45),
                                size: 22,
                              ),
                              tooltip: _obscureConfirm
                                  ? 'Show confirm password'
                                  : 'Hide confirm password',
                            ),
                          ),
                        ],

                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.redAccent.withValues(alpha: 0.25),
                              ),
                            ),
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),

                        // Primary Create account / Sign in pill
                        SizedBox(
                          height: 56,
                          child: ElevatedButton(
                            onPressed:
                                _busy || _googleBusy ? null : _submitEmailAuth,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: pillLavender,
                              disabledBackgroundColor:
                                  pillLavender.withValues(alpha: 0.65),
                              foregroundColor: pillLavenderText,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(32),
                              ),
                            ),
                            child: _busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.3,
                                      color: pillLavenderText,
                                    ),
                                  )
                                : Text(
                                    _isRegister ? 'Create account' : 'Sign in',
                                    style: const TextStyle(
                                      fontSize: 16.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),

                        const SizedBox(height: 18),

                        // Toggle Sign in / Create account
                        Center(
                          child: TextButton(
                            onPressed: _busy || _googleBusy
                                ? null
                                : () => setState(() {
                                      _isRegister = !_isRegister;
                                      _error = null;
                                    }),
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  color: Color(0xFF49454F),
                                ),
                                children: [
                                  TextSpan(
                                    text: _isRegister
                                        ? 'Already have an account? '
                                        : 'New to Lakbay+? ',
                                  ),
                                  TextSpan(
                                    text:
                                        _isRegister ? 'Sign in' : 'Create account',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF1F1629),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Legal Footer
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
              child: RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: Color(0xFF6B6570),
                  ),
                  children: [
                    const TextSpan(text: 'By continuing you agree to the '),
                    TextSpan(
                      text: 'Terms',
                      style: const TextStyle(
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w600,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => _showLegalDialog(
                              context,
                              'Terms of Service',
                              'Lakbay+ provides AI-assisted travel planning across Davao Region (Region XI). Market rates and schedules are synced from verified Lakbay+ partners and local databases; always confirm live operator availability before departure.',
                            ),
                    ),
                    const TextSpan(text: ' and\n'),
                    TextSpan(
                      text: 'Privacy Policy.',
                      style: const TextStyle(
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w600,
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final TextInputType keyboardType;
  final bool obscureText;
  final Widget? suffixIcon;
  final Color borderColor;

  const _AuthTextField({
    required this.controller,
    required this.hintText,
    this.keyboardType = TextInputType.text,
    this.obscureText = false,
    this.suffixIcon,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      style: const TextStyle(
        fontSize: 15.5,
        color: Color(0xFF1F1629),
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(
          color: Color(0xFF8C8793),
          fontSize: 15.5,
        ),
        filled: true,
        fillColor: const Color(0xFFFAF7F4),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        suffixIcon: suffixIcon,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: borderColor, width: 1.2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFF8C6CEB), width: 1.6),
        ),
      ),
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
