import 'package:flutter/material.dart';

/// Keeps QA unmistakable while leaving production builds untouched.
class QaEnvironmentFrame extends StatelessWidget {
  const QaEnvironmentFrame({
    super.key,
    required this.enabled,
    required this.locale,
    required this.child,
  });

  final bool enabled;
  final Locale locale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    final isArabic = locale.languageCode == 'ar';
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: SizedBox(
            width: double.infinity,
            height: 32,
            child: ColoredBox(
              color: const Color(0xffb45309),
              child: Center(
                child: Text(
                  isArabic
                      ? 'بيئة تجريبية QA • لا تستخدم بيانات أو مدفوعات حقيقية'
                      : 'QA TEST ENVIRONMENT • No real data or payments',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .15,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
