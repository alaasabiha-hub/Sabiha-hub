import 'dart:math' as math;

import 'package:flutter/material.dart';

const hubNavy = Color(0xFF071A36),
    hubBlue = Color(0xFF174B83),
    hubSilver = Color(0xFFC5CBD5);
const approvedBrandAsset = 'assets/sabiha_brand_approved.png';

class HubBrandHeader extends StatelessWidget {
  final bool arabic;
  final ValueChanged<String> onLanguage;
  final VoidCallback onLogin;
  const HubBrandHeader({
    super.key,
    required this.arabic,
    required this.onLanguage,
    required this.onLogin,
  });
  Widget brand() => Semantics(
    label: 'Sabiha Hub · A New Concept in Total Care',
    image: true,
    child: SizedBox(
      height: 100,
      child: Image.asset(
        approvedBrandAsset,
        fit: BoxFit.contain,
        key: const ValueKey('welcome-full-original-logo'),
        excludeFromSemantics: true,
      ),
    ),
  );
  Widget controls() => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    runSpacing: 8,
    textDirection: TextDirection.ltr,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: hubBlue),
          borderRadius: BorderRadius.circular(24),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.ltr,
            children: [
              for (final code in ['en', 'ar'])
                Semantics(
                  selected: arabic == (code == 'ar'),
                  child: TextButton(
                    key: ValueKey('welcome_language_$code'),
                    onPressed: () => onLanguage(code),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(38, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor: arabic == (code == 'ar')
                          ? hubBlue
                          : Colors.white,
                      foregroundColor: arabic == (code == 'ar')
                          ? Colors.white
                          : hubNavy,
                      shape: const RoundedRectangleBorder(),
                    ),
                    child: Text(
                      code == 'ar' ? 'عربي' : 'EN',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      FilledButton(
        key: const ValueKey('welcome_login'),
        onPressed: onLogin,
        style: FilledButton.styleFrom(
          backgroundColor: hubNavy,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          minimumSize: const Size(70, 42),
        ),
        child: Text(
          arabic ? 'تسجيل الدخول' : 'Sign in',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: LayoutBuilder(
        builder: (c, b) {
          final stack =
              b.maxWidth < 350 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.1;
          return stack
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: b.maxWidth, child: brand()),
                    const SizedBox(height: 10),
                    SizedBox(width: b.maxWidth, child: controls()),
                  ],
                )
              : Row(
                  textDirection: TextDirection.ltr,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(width: b.maxWidth - 188, child: brand()),
                    SizedBox(width: 180, child: controls()),
                  ],
                );
        },
      ),
    ),
  );
}

class HubWelcomeScreen extends StatelessWidget {
  final bool arabic;
  final ValueChanged<String> onLanguage;
  final VoidCallback onLogin, onBook, onServices, onStaff;
  final VoidCallback? onOffers;
  final Widget? support;
  const HubWelcomeScreen({
    super.key,
    required this.arabic,
    required this.onLanguage,
    required this.onLogin,
    required this.onBook,
    required this.onServices,
    required this.onStaff,
    this.onOffers,
    this.support,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (c, b) => SingleChildScrollView(
          child: Column(
            children: [
              HubBrandHeader(
                arabic: arabic,
                onLanguage: onLanguage,
                onLogin: onLogin,
              ),
              Container(
                width: double.infinity,
                constraints: BoxConstraints(
                  minHeight: math.max(490, b.maxHeight - 155),
                ),
                decoration: const BoxDecoration(
                  image: DecorationImage(
                    image: AssetImage('assets/customer/night-car.jpg'),
                    fit: BoxFit.cover,
                    colorFilter: ColorFilter.mode(
                      Color(0xE6071A36),
                      BlendMode.srcATop,
                    ),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF1B3D62),
                      Color(0xFF14314D),
                      Color(0xFF081B2D),
                    ],
                    stops: [0, .45, 1],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x55121E2D),
                      blurRadius: 7,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 28,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: math.min(b.maxWidth - 44, 380),
                      height: math.min((b.maxWidth - 44) * .51, 194),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Image.asset(
                            approvedBrandAsset,
                            fit: BoxFit.contain,
                            semanticLabel: 'Original Sabiha Hub logo',
                          ),
                        ),
                      ),
                    ),
                    const Text(
                      'Sabiha Hub',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        color: hubSilver,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'مفهوم جديد للعناية المتكاملة',
                      key: ValueKey('public-official-tagline-ar'),
                      textDirection: TextDirection.rtl,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'A New Concept in Total Care',
                      key: ValueKey('public-official-tagline-en'),
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: hubSilver,
                        fontSize: 18,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 26),
                    LayoutBuilder(
                      builder: (c, width) {
                        final buttons = [
                          _WelcomeButton(
                            primary: true,
                            label: arabic
                                ? 'احجز خدمتك الآن'
                                : 'Book Your Service',
                            icon: Icons.event_available_outlined,
                            onPressed: onBook,
                          ),
                          _WelcomeButton(
                            primary: false,
                            label: arabic
                                ? 'اكتشف خدماتنا'
                                : 'Explore Services',
                            icon: Icons.chevron_right,
                            onPressed: onServices,
                          ),
                        ];
                        return width.maxWidth < 370 ||
                                MediaQuery.textScalerOf(context).scale(1) > 1.1
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  buttons[0],
                                  const SizedBox(height: 12),
                                  buttons[1],
                                ],
                              )
                            : Row(
                                textDirection: TextDirection.ltr,
                                children: [
                                  Expanded(child: buttons[0]),
                                  const SizedBox(width: 12),
                                  Expanded(child: buttons[1]),
                                ],
                              );
                      },
                    ),
                  ],
                ),
              ),
              if (onOffers != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    key: const ValueKey('welcome_offers'),
                    onPressed: onOffers,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD4AF37),
                      foregroundColor: hubNavy,
                    ),
                    icon: const Icon(Icons.sell_outlined),
                    label: Text(
                      arabic ? 'العروض والباقات' : 'Offers & packages',
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 20,
                ),
                child: TextButton(
                  key: const ValueKey('welcome_staff'),
                  onPressed: onStaff,
                  child: Text(
                    arabic ? 'تسجيل دخول الموظفين' : 'Staff Sign In',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: hubBlue,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              ?support,
            ],
          ),
        ),
      ),
    ),
  );
}

class _WelcomeButton extends StatelessWidget {
  final bool primary;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  const _WelcomeButton({
    required this.primary,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(15),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: primary
            ? const [Color(0xFF59B5F4), Color(0xFF1E70B2), Color(0xFF17456B)]
            : const [Colors.white, Color(0xFFF0F3F8)],
      ),
      border: Border.all(
        color: primary ? const Color(0xFF94CEEF) : Colors.white,
      ),
      boxShadow: primary
          ? const [BoxShadow(color: Color(0x6655B8F4), blurRadius: 14)]
          : const [BoxShadow(color: Color(0x33000818), blurRadius: 6)],
    ),
    child: TextButton(
      key: ValueKey(primary ? 'welcome_book' : 'welcome_services'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: primary ? Colors.white : hubNavy,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 21),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Full unchanged approved brand bitmap, including every wordmark and tagline.
class OriginalHubMark extends StatelessWidget {
  final double size;
  const OriginalHubMark({super.key, this.size = 74});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Image.asset(
      approvedBrandAsset,
      fit: BoxFit.contain,
      semanticLabel: 'Sabiha Hub',
    ),
  );
}
