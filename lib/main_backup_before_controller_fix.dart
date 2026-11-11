
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseUrl =
    'https://cujfeqsuanwxobtupxaz.supabase.co';

const String supabasePublishableKey =
    'sb_publishable_R4sMzFLo99u_tJCdiaE0HQ_4gqIff5J';

final supabase = Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabasePublishableKey,
  );

  runApp(const SabihaHubApp());
}

class SabihaHubApp extends StatefulWidget {
  const SabihaHubApp({super.key});

  @override
  State<SabihaHubApp> createState() => _SabihaHubAppState();
}

class _SabihaHubAppState extends State<SabihaHubApp> {
  Locale _locale = const Locale('ar');
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLanguage = prefs.getString('app_language') ?? 'ar';

    if (!mounted) return;

    setState(() {
      _locale = Locale(savedLanguage);
      _loading = false;
    });
  }

  Future<void> _changeLanguage(String language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', language);

    if (!mounted) return;

    setState(() {
      _locale = Locale(language);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFF071A36),
          body: Center(
            child: CircularProgressIndicator(
              color: Color(0xFFC5CBD5),
            ),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sabiha Hub',
      locale: _locale,
      supportedLocales: const [
        Locale('ar'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoNaskhArabic',
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF123B70),
          primary: const Color(0xFF123B70),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF071A36),
          foregroundColor: Colors.white,
          centerTitle: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFDCE2EA)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFDCE2EA)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
              color: Color(0xFF2463A6),
              width: 1.5,
            ),
          ),
        ),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: _locale.languageCode == 'ar'
              ? TextDirection.rtl
              : TextDirection.ltr,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: HomeScreen(
        locale: _locale,
        onLanguageChanged: _changeLanguage,
      ),
    );
  }
}

String tr(BuildContext context, String ar, String en) {
  return Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
}

const Color navy = Color(0xFF071A36);
const Color royalBlue = Color(0xFF174B83);
const Color silver = Color(0xFFC5CBD5);

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Widget brandLogo({double size = 76}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.25),
      gradient: const LinearGradient(
        colors: [Color(0xFF174B83), Color(0xFF071A36)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      border: Border.all(color: silver, width: 1.4),
      boxShadow: [
        BoxShadow(
          color: navy.withValues(alpha: 0.18),
          blurRadius: 15,
          offset: const Offset(0, 7),
        ),
      ],
    ),
    child: Center(
      child: Text(
        'SH',
        style: TextStyle(
          color: silver,
          fontSize: size * 0.39,
          fontWeight: FontWeight.w900,
          letterSpacing: -3,
        ),
      ),
    ),
  );
}

Widget languageButton(
  BuildContext context,
  Future<void> Function(String) onChanged,
) {
  final isArabic =
      Localizations.localeOf(context).languageCode == 'ar';

  return PopupMenuButton<String>(
    tooltip: tr(context, 'تغيير اللغة', 'Change language'),
    onSelected: onChanged,
    itemBuilder: (context) => [
      const PopupMenuItem(
        value: 'ar',
        child: Text('العربية'),
      ),
      const PopupMenuItem(
        value: 'en',
        child: Text('English'),
      ),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: silver.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.language, color: silver, size: 19),
          const SizedBox(width: 5),
          Text(
            isArabic ? 'عربي' : 'EN',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    ),
  );
}

// الشاشة الرئيسية
class HomeScreen extends StatelessWidget {
  final Locale locale;
  final Future<void> Function(String) onLanguageChanged;

  const HomeScreen({
    super.key,
    required this.locale,
    required this.onLanguageChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: navy,
      body: SafeArea(
        child: Stack(
          children: [
            PositionedDirectional(
              top: 12,
              start: 18,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: silver,
                  side: BorderSide(
                    color: silver.withValues(alpha: 0.7),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.badge_outlined, size: 17),
                label: Text(
                  tr(context, 'دخول الموظفين', 'Staff Login'),
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const StaffLoginScreen(),
                    ),
                  );
                },
              ),
            ),
            PositionedDirectional(
              top: 12,
              end: 18,
              child: languageButton(context, onLanguageChanged),
            ),
            Column(
              children: [
                const Spacer(),
                brandLogo(size: 112),
                const SizedBox(height: 20),
                const Text(
                  'SABIHA HUB',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 29,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    context,
                    'العناية بسيارتك تبدأ من هنا',
                    'Your car care starts here',
                  ),
                  style: const TextStyle(
                    color: silver,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 55),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: navy,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(Icons.person_outline),
                      label: Text(
                        tr(context, 'دخول العميل', 'Customer Login'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CustomerLoginScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text(
                    'SABIHA HUB  •  PREMIUM CAR CARE',
                    style: TextStyle(
                      color: silver.withValues(alpha: 0.65),
                      fontSize: 10,
                      letterSpacing: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// تسجيل دخول العميل
class CustomerLoginScreen extends StatefulWidget {
  const CustomerLoginScreen({super.key});

  @override
  State<CustomerLoginScreen> createState() => _CustomerLoginScreenState();
}

class _CustomerLoginScreenState extends State<CustomerLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _hidePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showMessage(
        context,
        tr(
          context,
          'أدخل البريد الإلكتروني وكلمة المرور',
          'Enter email and password',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      final response = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = response.user;

      if (user == null) {
        throw Exception(
          tr(context, 'تعذر تسجيل الدخول', 'Login failed'),
        );
      }

      final profile = await supabase
          .from('customers')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        await supabase.auth.signOut();
        throw Exception(
          tr(
            context,
            'لم يتم العثور على ملف العميل. تواصل مع الإدارة.',
            'Customer profile was not found. Please contact support.',
          ),
        );
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => CustomerDashboardScreen(
            customerName:
                user.userMetadata?['full_name']?.toString() ?? '',
          ),
        ),
      );
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'دخول العميل', 'Customer Login')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 15),
              brandLogo(),
              const SizedBox(height: 15),
              Text(
                tr(
                  context,
                  'مرحباً بك في Sabiha Hub',
                  'Welcome to Sabiha Hub',
                ),
                style: const TextStyle(
                  color: navy,
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(
                    context,
                    'البريد الإلكتروني',
                    'Email address',
                  ),
                  prefixIcon: const Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: _hidePassword,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(context, 'كلمة المرور', 'Password'),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() => _hidePassword = !_hidePassword);
                    },
                    icon: Icon(
                      _hidePassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ForgotPasswordScreen(),
                      ),
                    );
                  },
                  child: Text(
                    tr(context, 'نسيت كلمة المرور؟', 'Forgot password?'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _loading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: navy,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(
                          color: Colors.white,
                        )
                      : Text(
                          tr(context, 'تسجيل الدخول', 'Sign in'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    tr(context, 'ليس لديك حساب؟', 'New customer?'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(),
                        ),
                      );
                    },
                    child: Text(
                      tr(context, 'إنشاء حساب', 'Create account'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// إنشاء حساب عميل
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _birthController = TextEditingController();

  bool _loading = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _birthController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;
    final birthDate = _birthController.text.trim();

    if (name.isEmpty ||
        phone.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      showMessage(
        context,
        tr(
          context,
          'يرجى إدخال جميع البيانات المطلوبة',
          'Please complete all required fields',
        ),
      );
      return;
    }

    if (password.length < 6) {
      showMessage(
        context,
        tr(
          context,
          'كلمة المرور يجب ألا تقل عن 6 أحرف',
          'Password must be at least 6 characters',
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      showMessage(
        context,
        tr(
          context,
          'كلمتا المرور غير متطابقتين',
          'Passwords do not match',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      final response = await supabase.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': name,
          'phone': phone,
          'date_of_birth': birthDate,
        },
      );

      if (response.user == null) {
        throw Exception(
          tr(context, 'تعذر إنشاء الحساب', 'Could not create account'),
        );
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OtpVerificationScreen(
            email: email,
            customerName: name,
          ),
        ),
      );
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseBirthDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime(2000),
      firstDate: DateTime(1920),
      lastDate: DateTime.now(),
    );

    if (selected != null) {
      _birthController.text =
          '${selected.year.toString().padLeft(4, '0')}-'
          '${selected.month.toString().padLeft(2, '0')}-'
          '${selected.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'إنشاء حساب جديد', 'Create Account')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            children: [
              brandLogo(size: 65),
              const SizedBox(height: 22),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: tr(context, 'الاسم بالكامل', 'Full name'),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                decoration: InputDecoration(
                  labelText: tr(context, 'رقم الهاتف', 'Phone number'),
                  prefixIcon: const Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(
                    context,
                    'البريد الإلكتروني',
                    'Email address',
                  ),
                  prefixIcon: const Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _birthController,
                readOnly: true,
                onTap: _chooseBirthDate,
                decoration: InputDecoration(
                  labelText: tr(
                    context,
                    'تاريخ الميلاد (اختياري)',
                    'Date of birth (optional)',
                  ),
                  prefixIcon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passwordController,
                obscureText: _hidePassword,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(context, 'كلمة المرور', 'Password'),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() {
                        _hidePassword = !_hidePassword;
                      });
                    },
                    icon: Icon(
                      _hidePassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _confirmPasswordController,
                obscureText: _hideConfirmPassword,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(
                    context,
                    'تأكيد كلمة المرور',
                    'Confirm password',
                  ),
                  prefixIcon: const Icon(Icons.lock_reset_outlined),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() {
                        _hideConfirmPassword = !_hideConfirmPassword;
                      });
                    },
                    icon: Icon(
                      _hideConfirmPassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _loading ? null : _register,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: navy,
                    foregroundColor: Colors.white,
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(
                          color: Colors.white,
                        )
                      : Text(
                          tr(
                            context,
                            'إنشاء الحساب وإرسال رمز التحقق',
                            'Create account and send code',
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// التحقق من البريد الإلكتروني
class OtpVerificationScreen extends StatefulWidget {
  final String email;
  final String customerName;

  const OtpVerificationScreen({
    super.key,
    required this.email,
    required this.customerName,
  });

  @override
  State<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState
    extends State<OtpVerificationScreen> {
  final _codeController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();

    if (code.length != 8) {
      showMessage(
        context,
        tr(
          context,
          'أدخل رمز التحقق المكوّن من 8 أرقام',
          'Enter the 8-digit verification code',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.verifyOTP(
        email: widget.email,
        token: code,
        type: OtpType.signup,
      );

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => CustomerDashboardScreen(
            customerName: widget.customerName,
          ),
        ),
        (route) => false,
      );
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    try {
      await supabase.auth.resend(
        email: widget.email,
        type: OtpType.signup,
      );

      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تم طلب إرسال رمز جديد إلى بريدك',
            'A new code has been requested',
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr(context, 'تأكيد البريد الإلكتروني', 'Verify Email'),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 35),
            const Icon(
              Icons.mark_email_read_outlined,
              size: 75,
              color: royalBlue,
            ),
            const SizedBox(height: 20),
            Text(
              tr(
                context,
                'أرسلنا رمز التحقق إلى',
                'We sent a verification code to',
              ),
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 8),
            Text(
              widget.email,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: royalBlue,
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: tr(context, 'رمز التحقق', 'Verification code'),
                counterText: '',
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _loading ? null : _verify,
                style: ElevatedButton.styleFrom(
                  backgroundColor: navy,
                  foregroundColor: Colors.white,
                ),
                child: _loading
                    ? const CircularProgressIndicator(
                        color: Colors.white,
                      )
                    : Text(
                        tr(context, 'تأكيد الحساب', 'Verify account'),
                      ),
              ),
            ),
            TextButton(
              onPressed: _resend,
              child: Text(
                tr(context, 'إعادة إرسال الرمز', 'Resend code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// استعادة كلمة المرور - ثلاث مراحل
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  int _step = 0;
  bool _loading = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      showMessage(
        context,
        tr(context, 'أدخل البريد الإلكتروني', 'Enter your email address'),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.resetPasswordForEmail(email);

      if (!mounted) return;

      setState(() => _step = 1);

      showMessage(
        context,
        tr(
          context,
          'إذا كان البريد مسجلاً، ستصلك رسالة تحتوي على رمز الاستعادة',
          'If the email is registered, you will receive a reset code',
        ),
      );
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyResetCode() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();

    if (code.length != 8) {
      showMessage(
        context,
        tr(
          context,
          'أدخل رمز التحقق المكوّن من 8 أرقام',
          'Enter the 8-digit verification code',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.recovery,
      );

      if (!mounted) return;

      setState(() => _step = 2);

      showMessage(
        context,
        tr(
          context,
          'تم التحقق من الرمز. أدخل كلمة المرور الجديدة',
          'Code verified. Enter your new password',
        ),
      );
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updatePassword() async {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (password.length < 6) {
      showMessage(
        context,
        tr(
          context,
          'كلمة المرور يجب ألا تقل عن 6 أحرف',
          'Password must be at least 6 characters',
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      showMessage(
        context,
        tr(
          context,
          'كلمتا المرور غير متطابقتين',
          'Passwords do not match',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.updateUser(
        UserAttributes(password: password),
      );

      if (!mounted) return;

      showMessage(
        context,
        tr(
          context,
          'تم تغيير كلمة المرور بنجاح',
          'Your password has been changed successfully',
        ),
      );

      Navigator.pop(context);
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resendResetCode() async {
    final email = _emailController.text.trim();

    setState(() => _loading = true);

    try {
      await supabase.auth.resetPasswordForEmail(email);

      if (mounted) {
        _codeController.clear();
        showMessage(
          context,
          tr(
            context,
            'تم طلب إرسال رمز استعادة جديد',
            'A new recovery code has been requested',
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildEmailStep() {
    return Column(
      children: [
        Text(
          tr(
            context,
            'أدخل بريدك الإلكتروني لإرسال رمز استعادة كلمة المرور',
            'Enter your email to receive a password recovery code',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 25),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(
              context,
              'البريد الإلكتروني',
              'Email address',
            ),
            prefixIcon: const Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 22),
        _actionButton(
          label: tr(context, 'إرسال رمز التحقق', 'Send verification code'),
          onPressed: _sendResetCode,
        ),
      ],
    );
  }

  Widget _buildCodeStep() {
    return Column(
      children: [
        Text(
          tr(
            context,
            'أدخل رمز التحقق المكوّن من 8 أرقام الذي أرسلناه إلى',
            'Enter the 8-digit code sent to',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          _emailController.text.trim(),
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: royalBlue,
          ),
        ),
        const SizedBox(height: 25),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          maxLength: 8,
          decoration: InputDecoration(
            labelText: tr(context, 'رمز التحقق', 'Verification code'),
            counterText: '',
            prefixIcon: const Icon(Icons.password),
          ),
        ),
        const SizedBox(height: 22),
        _actionButton(
          label: tr(context, 'التحقق من الرمز', 'Verify code'),
          onPressed: _verifyResetCode,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _loading ? null : _resendResetCode,
          child: Text(
            tr(context, 'إعادة إرسال الرمز', 'Resend code'),
          ),
        ),
        TextButton(
          onPressed: _loading
              ? null
              : () {
                  setState(() {
                    _step = 0;
                    _codeController.clear();
                  });
                },
          child: Text(
            tr(context, 'تغيير البريد الإلكتروني', 'Change email address'),
          ),
        ),
      ],
    );
  }

  Widget _buildNewPasswordStep() {
    return Column(
      children: [
        Text(
          tr(
            context,
            'أدخل كلمة المرور الجديدة لحسابك',
            'Enter a new password for your account',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 25),
        TextField(
          controller: _passwordController,
          obscureText: _hidePassword,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(context, 'كلمة المرور الجديدة', 'New password'),
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () {
                setState(() => _hidePassword = !_hidePassword);
              },
              icon: Icon(
                _hidePassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmPasswordController,
          obscureText: _hideConfirmPassword,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(
              context,
              'تأكيد كلمة المرور الجديدة',
              'Confirm new password',
            ),
            prefixIcon: const Icon(Icons.lock_reset_outlined),
            suffixIcon: IconButton(
              onPressed: () {
                setState(() {
                  _hideConfirmPassword = !_hideConfirmPassword;
                });
              },
              icon: Icon(
                _hideConfirmPassword
                    ? Icons.visibility
                    : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        _actionButton(
          label: tr(context, 'حفظ كلمة المرور الجديدة', 'Save new password'),
          onPressed: _updatePassword,
        ),
      ],
    );
  }

  Widget _actionButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: _loading
            ? const CircularProgressIndicator(color: Colors.white)
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr(context, 'استعادة كلمة المرور', 'Reset Password'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 20),
              const Icon(
                Icons.lock_reset,
                size: 75,
                color: royalBlue,
              ),
              const SizedBox(height: 20),
              Text(
                tr(
                  context,
                  'استعادة حساب Sabiha Hub',
                  'Recover your Sabiha Hub account',
                ),
                style: const TextStyle(
                  color: navy,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  context,
                  'الخطوة ${_step + 1} من 3',
                  'Step ${_step + 1} of 3',
                ),
                style: const TextStyle(
                  color: royalBlue,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 25),
              if (_step == 0) _buildEmailStep(),
              if (_step == 1) _buildCodeStep(),
              if (_step == 2) _buildNewPasswordStep(),
            ],
          ),
        ),
      ),
    );
  }
}

// لوحة العميل
class CustomerDashboardScreen extends StatelessWidget {
  final String customerName;

  const CustomerDashboardScreen({
    super.key,
    required this.customerName,
  });

  Future<void> _logout(BuildContext context) async {
    await supabase.auth.signOut();

    if (!context.mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          locale: Localizations.localeOf(context),
          onLanguageChanged: (language) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('app_language', language);
          },
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = customerName.isEmpty
        ? tr(context, 'عميلنا العزيز', 'Dear customer')
        : customerName;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SABIHA HUB'),
        actions: [
          IconButton(
            tooltip: tr(context, 'تسجيل الخروج', 'Sign out'),
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [navy, royalBlue],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(
                        context,
                        'أهلاً بك، $name',
                        'Welcome, $name',
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr(
                        context,
                        'يسعدنا خدمتك في Sabiha Hub',
                        'We are happy to serve you at Sabiha Hub',
                      ),
                      style: const TextStyle(color: silver),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 25),
              _DashboardTile(
                icon: Icons.local_car_wash_outlined,
                title: tr(context, 'احجز خدمة', 'Book a service'),
                subtitle: tr(
                  context,
                  'اختر الخدمة المناسبة لسيارتك',
                  'Choose the right service for your car',
                ),
                onTap: () => showMessage(
                  context,
                  tr(
                    context,
                    'سيتم تفعيل الحجوزات في المرحلة القادمة',
                    'Booking will be enabled in the next stage',
                  ),
                ),
              ),
              _DashboardTile(
                icon: Icons.directions_car_outlined,
                title: tr(context, 'سياراتي', 'My vehicles'),
                subtitle: tr(
                  context,
                  'إدارة بيانات سياراتك',
                  'Manage your vehicles',
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MyVehiclesScreen(),
                    ),
                  );
                },
              ),
              _DashboardTile(
                icon: Icons.receipt_long_outlined,
                title: tr(
                  context,
                  'طلباتي وفواتيري',
                  'My orders and invoices',
                ),
                subtitle: tr(
                  context,
                  'متابعة الطلبات والفواتير',
                  'Track orders and invoices',
                ),
                onTap: () => showMessage(
                  context,
                  tr(
                    context,
                    'سيتم تفعيل هذه الخدمة قريباً',
                    'This feature will be enabled soon',
                  ),
                ),
              ),
              _DashboardTile(
                icon: Icons.person_outline,
                title: tr(context, 'حسابي', 'My account'),
                subtitle: tr(
                  context,
                  'بيانات حساب العميل',
                  'Customer account details',
                ),
                onTap: () => showMessage(
                  context,
                  tr(
                    context,
                    'سيتم تفعيل هذه الخدمة قريباً',
                    'This feature will be enabled soon',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


// شاشة سيارات العميل
class MyVehiclesScreen extends StatefulWidget {
  const MyVehiclesScreen({super.key});

  @override
  State<MyVehiclesScreen> createState() => _MyVehiclesScreenState();
}

class _MyVehiclesScreenState extends State<MyVehiclesScreen> {
  List<Map<String, dynamic>> _vehicles = [];
  bool _loading = true;

  String get _userId => supabase.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  Future<void> _loadVehicles() async {
    if (_userId.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);

    try {
      final result = await supabase
          .from('vehicles')
          .select()
          .eq('customer_id', _userId)
          .order('created_at', ascending: false);

      if (!mounted) return;

      setState(() {
        _vehicles = List<Map<String, dynamic>>.from(result);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message(
        tr(context, 'تعذر تحميل السيارات', 'Could not load vehicles'),
      );
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value)),
    );
  }

  Future<void> _showVehicleDialog({
    Map<String, dynamic>? vehicle,
  }) async {
    final brand = TextEditingController(
      text: vehicle?['brand']?.toString() ?? '',
    );
    final model = TextEditingController(
      text: vehicle?['model']?.toString() ?? '',
    );
    final year = TextEditingController(
      text: vehicle?['year']?.toString() ?? '',
    );
    final color = TextEditingController(
      text: vehicle?['color']?.toString() ?? '',
    );
    final plate = TextEditingController(
      text: vehicle?['plate_number']?.toString() ?? '',
    );

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          vehicle == null
              ? tr(context, 'إضافة سيارة', 'Add vehicle')
              : tr(context, 'تعديل السيارة', 'Edit vehicle'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: brand,
                decoration: InputDecoration(
                  labelText: tr(context, 'الماركة', 'Brand'),
                ),
              ),
              TextField(
                controller: model,
                decoration: InputDecoration(
                  labelText: tr(context, 'الموديل', 'Model'),
                ),
              ),
              TextField(
                controller: year,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr(context, 'سنة الصنع', 'Year'),
                ),
              ),
              TextField(
                controller: color,
                decoration: InputDecoration(
                  labelText: tr(context, 'اللون', 'Color'),
                ),
              ),
              TextField(
                controller: plate,
                decoration: InputDecoration(
                  labelText: tr(context, 'رقم اللوحة', 'Plate number'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr(context, 'إلغاء', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              final enteredYear = year.text.trim();
              final parsedYear = enteredYear.isEmpty
                  ? null
                  : int.tryParse(enteredYear);

              if (brand.text.trim().isEmpty ||
                  model.text.trim().isEmpty ||
                  plate.text.trim().isEmpty) {
                _message(
                  tr(
                    context,
                    'أدخل الماركة والموديل ورقم اللوحة',
                    'Enter brand, model and plate number',
                  ),
                );
                return;
              }

              if (enteredYear.isNotEmpty &&
                  (parsedYear == null ||
                      parsedYear < 1950 ||
                      parsedYear > 2100)) {
                _message(
                  tr(
                    context,
                    'سنة الصنع غير صحيحة',
                    'Invalid vehicle year',
                  ),
                );
                return;
              }

              final data = <String, dynamic>{
                'brand': brand.text.trim(),
                'model': model.text.trim(),
                'year': parsedYear,
                'color': color.text.trim().isEmpty
                    ? null
                    : color.text.trim(),
                'plate_number': plate.text.trim(),
              };

              try {
                if (vehicle == null) {
                  await supabase.from('vehicles').insert({
                    ...data,
                    'customer_id': _userId,
                  });
                } else {
                  await supabase
                      .from('vehicles')
                      .update(data)
                      .eq('id', vehicle['id'])
                      .eq('customer_id', _userId);
                }

                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                await _loadVehicles();

                if (mounted) {
                  _message(
                    tr(context, 'تم حفظ السيارة بنجاح', 'Vehicle saved'),
                  );
                }
              } catch (e) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(
                      content: Text(
                        tr(
                          context,
                          'تعذر حفظ السيارة. تحقق من رقم اللوحة والبيانات.',
                          'Could not save vehicle. Check the plate number and details.',
                        ),
                      ),
                    ),
                  );
                }
              }
            },
            child: Text(tr(context, 'حفظ', 'Save')),
          ),
        ],
      ),
    );

    brand.dispose();
    model.dispose();
    year.dispose();
    color.dispose();
    plate.dispose();
  }

  Future<void> _deleteVehicle(Map<String, dynamic> vehicle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'حذف السيارة', 'Delete vehicle')),
        content: Text(
          tr(
            context,
            'هل أنت متأكد من حذف هذه السيارة؟',
            'Are you sure you want to delete this vehicle?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'إلغاء', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, 'حذف', 'Delete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await supabase
          .from('vehicles')
          .delete()
          .eq('id', vehicle['id'])
          .eq('customer_id', _userId);

      await _loadVehicles();

      if (mounted) {
        _message(tr(context, 'تم حذف السيارة', 'Vehicle deleted'));
      }
    } catch (e) {
      if (mounted) {
        _message(tr(context, 'تعذر حذف السيارة', 'Could not delete vehicle'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'سياراتي', 'My vehicles')),
        backgroundColor: navy,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showVehicleDialog(),
        backgroundColor: royalBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'إضافة سيارة', 'Add vehicle')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _userId.isEmpty
              ? Center(
                  child: Text(
                    tr(
                      context,
                      'يرجى تسجيل الدخول مرة أخرى',
                      'Please sign in again',
                    ),
                  ),
                )
              : _vehicles.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.directions_car_outlined,
                              size: 65,
                              color: silver,
                            ),
                            const SizedBox(height: 15),
                            Text(
                              tr(
                                context,
                                'لم تضف أي سيارة حتى الآن',
                                'You have not added any vehicles yet',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              tr(
                                context,
                                'اضغط على إضافة سيارة للبدء',
                                'Tap Add vehicle to get started',
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadVehicles,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                        itemCount: _vehicles.length,
                        itemBuilder: (context, index) {
                          final vehicle = _vehicles[index];

                          final details = [
                            vehicle['year']?.toString(),
                            vehicle['color']?.toString(),
                          ].where((value) =>
                              value != null && value.isNotEmpty).join(' • ');

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: const Color(0xFFEAF0F8),
                                child: Icon(
                                  Icons.directions_car,
                                  color: royalBlue,
                                ),
                              ),
                              title: Text(
                                '${vehicle['brand']} ${vehicle['model']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                [
                                  vehicle['plate_number']?.toString() ?? '',
                                  details,
                                ].where((value) => value.isNotEmpty).join('\n'),
                              ),
                              isThreeLine: details.isNotEmpty,
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'edit') {
                                    _showVehicleDialog(vehicle: vehicle);
                                  } else if (value == 'delete') {
                                    _deleteVehicle(vehicle);
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text(tr(context, 'تعديل', 'Edit')),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(tr(context, 'حذف', 'Delete')),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _DashboardTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DashboardTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 17,
          vertical: 10,
        ),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFEAF0F8),
          child: Icon(icon, color: royalBlue),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

// دخول الموظفين
class StaffLoginScreen extends StatelessWidget {
  const StaffLoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'دخول الموظفين', 'Staff Login')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            brandLogo(),
            const SizedBox(height: 25),
            Text(
              tr(context, 'بوابة الموظفين', 'Staff Portal'),
              style: const TextStyle(
                color: navy,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 15),
            Text(
              tr(
                context,
                'سيتم ربط تسجيل دخول الموظفين وصلاحيات الإدارة في المرحلة التالية.',
                'Staff authentication and management permissions will be connected in the next stage.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
