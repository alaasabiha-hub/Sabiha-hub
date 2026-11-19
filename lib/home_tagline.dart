import 'package:flutter/material.dart';

/// Approved home-page copy only; not a replacement for the official logo/tagline.
class HomeTagline extends StatelessWidget {
  final bool onDark;
  const HomeTagline({super.key, this.onDark = false});
  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          ar ? 'لأن سيارتك تستحق الأفضل' : 'Because Your Car Deserves the Best',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: onDark ? Colors.white : const Color(0xFF071A36),
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          ar ? 'اغسل سيارتك بسهولة' : 'Wash Your Car with Ease',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: onDark ? const Color(0xFFC5CBD5) : const Color(0xFF174B83),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
