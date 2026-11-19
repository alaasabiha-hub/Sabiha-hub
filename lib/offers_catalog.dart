import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home_tagline.dart';

import 'welcome_ui.dart' show approvedBrandAsset, hubBlue, hubNavy, hubSilver;

const promotionGold = Color(0xFFD4AF37);

/// Public, data-driven layout. Signed-in customer screens keep their own shell.
class OffersCatalogPage extends StatefulWidget {
  final List<Map<String, dynamic>> offers, coupons;
  final int? points;
  final bool loading, failed, localDevelopment, isLanding;
  final VoidCallback onRetry,
      onHome,
      onServices,
      onBooking,
      onAccount,
      onLanguage;
  final VoidCallback? onStaff, onCareers;
  final VoidCallback? onShop;
  final Widget? support;
  final ValueChanged<Map<String, dynamic>> onBookOffer;
  const OffersCatalogPage({
    super.key,
    required this.offers,
    required this.coupons,
    required this.points,
    required this.loading,
    required this.failed,
    required this.onRetry,
    required this.onHome,
    required this.onServices,
    required this.onBooking,
    required this.onAccount,
    required this.onLanguage,
    required this.onBookOffer,
    this.onStaff,
    this.onCareers,
    this.onShop,
    this.support,
    this.isLanding = false,
    this.localDevelopment = true,
  });
  @override
  State<OffersCatalogPage> createState() => _OffersCatalogPageState();
}

class _OffersCatalogPageState extends State<OffersCatalogPage> {
  final scaffold = GlobalKey<ScaffoldState>();
  final scroll = ScrollController(),
      pages = PageController(viewportFraction: .94);
  final sectionKey = GlobalKey();
  String category = 'package';
  int pageIndex = 0;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  String localized(Map<String, dynamic> row, String field) =>
      Localizations.localeOf(context).languageCode == 'en' &&
          '${row['${field}_en'] ?? ''}'.trim().isNotEmpty
      ? '${row['${field}_en']}'
      : '${row[field] ?? ''}';
  String localizedVehicleClass(Map<String, dynamic> row) {
    final field = Localizations.localeOf(context).languageCode == 'en'
        ? 'name_en'
        : 'name_ar';
    return '${row[field] ?? row['class_code'] ?? ''}';
  }

  @override
  void dispose() {
    scroll.dispose();
    pages.dispose();
    super.dispose();
  }

  void home() {
    if (widget.isLanding) {
      scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    } else {
      widget.onHome();
    }
  }

  void choose(String value, {bool reveal = false}) {
    setState(() {
      category = value;
      pageIndex = 0;
    });
    if (pages.hasClients) pages.jumpToPage(0);
    if (reveal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = sectionKey.currentContext;
        if (c != null) {
          Scrollable.ensureVisible(
            c,
            duration: const Duration(milliseconds: 260),
          );
        }
      });
    }
  }

  Widget action(
    String label,
    VoidCallback? callback, {
    bool offer = false,
    IconData icon = Icons.arrow_forward,
    Key? key,
  }) => FilledButton.icon(
    key: key,
    onPressed: callback,
    icon: Icon(icon, size: 20),
    label: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
    style: FilledButton.styleFrom(
      backgroundColor: offer ? promotionGold : hubBlue,
      foregroundColor: offer ? hubNavy : Colors.white,
      minimumSize: const Size(44, 46),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
    ),
  );
  Widget panel(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(20),
    String? image,
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: hubSilver, width: 1.1),
      gradient: const LinearGradient(
        colors: [Color(0xFF0B315B), Color(0xFF041A34)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      image: image == null
          ? null
          : DecorationImage(
              image: AssetImage(image),
              fit: BoxFit.cover,
              colorFilter: const ColorFilter.mode(
                Color(0xC9071A36),
                BlendMode.srcATop,
              ),
            ),
      boxShadow: const [BoxShadow(color: Color(0x331765AD), blurRadius: 16)],
    ),
    child: child,
  );
  Widget brand(double height, {bool homeCopy = false}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset(
        approvedBrandAsset,
        key: const ValueKey('public-original-logo'),
        height: height,
        fit: BoxFit.contain,
        semanticLabel: 'Sabiha Hub',
      ),
      if (homeCopy)
        const Padding(
          padding: EdgeInsets.only(top: 6, bottom: 8),
          child: HomeTagline(),
        ),
    ],
  );
  Widget languageButton() => TextButton(
    key: const ValueKey('public-language'),
    onPressed: widget.onLanguage,
    style: TextButton.styleFrom(
      minimumSize: const Size(40, 42),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    child: Text(t('EN', 'عربي'), style: const TextStyle(color: hubNavy)),
  );
  Widget accountButton() => IconButton(
    key: const ValueKey('public-client-login'),
    onPressed: widget.onAccount,
    tooltip: t('تسجيل الدخول', 'Sign in'),
    icon: const Icon(Icons.account_circle, color: hubNavy, size: 29),
  );
  Widget menuButton() => IconButton(
    onPressed: () => scaffold.currentState?.openDrawer(),
    tooltip: t('القائمة', 'Menu'),
    icon: const Icon(Icons.menu, color: hubNavy),
  );
  Widget header(bool compact, double maxWidth) => Container(
    key: const ValueKey('public-reference-header'),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [Colors.white, Color(0xFFE5EAF2)]),
      borderRadius: BorderRadius.only(
        bottomLeft: Radius.circular(compact ? 22 : 0),
        bottomRight: Radius.circular(compact ? 22 : 65),
      ),
    ),
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 12 : 32,
      vertical: compact ? 6 : 3,
    ),
    child: compact
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 48,
                child: Stack(
                  children: [
                    Align(alignment: Alignment.centerLeft, child: menuButton()),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [languageButton(), accountButton()],
                      ),
                    ),
                  ],
                ),
              ),
              Center(
                child: SizedBox(
                  key: const ValueKey('public-header-brand'),
                  width: math.min(maxWidth - 24, 720),
                  child: brand(96, homeCopy: widget.isLanding),
                ),
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: widget.isLanding ? 200 : 102,
                child: Stack(
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        key: const ValueKey('public-header-brand'),
                        width: 270,
                        child: brand(92, homeCopy: widget.isLanding),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            key: const ValueKey('public-client-login'),
                            onPressed: widget.onAccount,
                            child: Text(
                              t('تسجيل الدخول', 'Sign in'),
                              style: const TextStyle(
                                color: hubNavy,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          languageButton(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  textDirection: TextDirection.rtl,
                  children: [
                    nav(t('الرئيسية', 'Home'), home),
                    nav(t('خدماتنا', 'Services'), widget.onServices),
                    if (widget.onShop != null)
                      nav(t('المتجر', 'Shop'), widget.onShop!),
                    nav(t('الحجز', 'Booking'), widget.onBooking),
                    nav(
                      t('الباقات', 'Packages'),
                      () => choose('package', reveal: true),
                    ),
                    nav(
                      t('العروض', 'Offers'),
                      () => choose('limited', reveal: true),
                      active: true,
                    ),
                    if (widget.onCareers != null)
                      nav(
                        t('الوظائف', 'Careers'),
                        widget.onCareers!,
                        key: const ValueKey('public-careers-navigation'),
                      ),
                  ],
                ),
              ),
            ],
          ),
  );
  Widget nav(
    String label,
    VoidCallback callback, {
    bool active = false,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: TextButton(
      key: key,
      onPressed: callback,
      style: TextButton.styleFrom(
        backgroundColor: active ? hubNavy : null,
        foregroundColor: active ? promotionGold : hubNavy,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
      ),
    ),
  );

  Widget hero(bool mobile) => SizedBox(
    key: const ValueKey('public-premium-hero'),
    height: mobile ? 184 : 240,
    child: Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF032A53), Color(0xFF001127)],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: mobile ? 250 : 720,
            child: Image.asset(
              'assets/customer/reference-premium-car.jpg',
              fit: BoxFit.contain,
              alignment: Alignment.bottomLeft,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: mobile
                  ? const [Color(0x10071A36), Color(0xEE071A36)]
                  : const [
                      Colors.transparent,
                      Color(0x00071A36),
                      Color(0xEE071A36),
                    ],
              stops: mobile ? null : const [0, .4, 1],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            mobile ? 12 : 30,
            mobile ? 18 : 32,
            mobile ? 14 : 38,
            32,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: mobile ? 230 : 570,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: mobile ? 230 : 570,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        textDirection: TextDirection.rtl,
                        children: [
                          Icon(
                            Icons.sell_outlined,
                            color: promotionGold,
                            size: mobile ? 36 : 64,
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              t('العروض والباقات', 'Offers & packages'),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: mobile ? 25 : 38,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        t(
                          'مفهوم جديد للعناية المتكاملة',
                          'A New Concept in Total Care',
                        ),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: hubSilver,
                          fontSize: mobile ? 14 : 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 34,
          child: IgnorePointer(child: CustomPaint(painter: _OfferRibbon())),
        ),
      ],
    ),
  );
  Widget tabs() => LayoutBuilder(
    builder: (_, box) {
      final width = (box.maxWidth - 24) / 4;
      return Row(
        children: [
          for (final item in [
            (
              'limited',
              Icons.bolt_outlined,
              t('عروض محدودة', 'Limited offers'),
            ),
            (
              'package',
              Icons.layers_outlined,
              t('باقات العناية', 'Care packages'),
            ),
            (
              'coupon',
              Icons.confirmation_number_outlined,
              t('كوبونات الخصم', 'Coupons'),
            ),
            ('reward', Icons.card_giftcard, t('مكافآت الولاء', 'Rewards')),
          ])
            Expanded(
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  end: item.$1 == 'reward' ? 0 : 8,
                ),
                child: Semantics(
                  selected: category == item.$1,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(15),
                      gradient: LinearGradient(
                        colors: category == item.$1
                            ? const [Color(0xFF124E8D), hubNavy]
                            : const [Color(0xFF0A2849), Color(0xFF02182F)],
                      ),
                      border: Border.all(
                        color: category == item.$1 ? promotionGold : hubSilver,
                      ),
                      boxShadow: category == item.$1
                          ? const [
                              BoxShadow(
                                color: Color(0x55369EFF),
                                blurRadius: 10,
                              ),
                            ]
                          : null,
                    ),
                    child: TextButton(
                      key: ValueKey('public-category-${item.$1}'),
                      onPressed: () => choose(item.$1),
                      style: TextButton.styleFrom(
                        minimumSize: Size(width, 82),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(item.$2, color: promotionGold, size: 27),
                          const SizedBox(height: 7),
                          Text(
                            item.$3,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: box.maxWidth < 500 ? 12 : 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
  String photo(Map<String, dynamic> offer) => switch (offer['image_asset']) {
    'wash' => 'assets/customer/reference-wash.jpg',
    'interior' => 'assets/customer/reference-interior.jpg',
    _ => 'assets/customer/reference-premium-car.jpg',
  };
  Widget card(Map<String, dynamic> offer) {
    final classPrices = List<Map<String, dynamic>>.from(
      offer['vehicle_class_prices'] is List
          ? offer['vehicle_class_prices'] as List
          : const [],
    );
    final hasClassPrices = classPrices.isNotEmpty;
    final price = hasClassPrices ? null : offer['price'] as num?,
        previous = hasClassPrices ? null : offer['compare_price'] as num?;
    final discount = price != null && previous != null && previous > price
        ? ((previous - price) / previous * 100).floor()
        : classPrices
              .map((row) {
                final current = row['price'], old = row['compare_price'];
                return current is num && old is num && old > current
                    ? ((old - current) / old * 100).floor()
                    : 0;
              })
              .fold<int>(
                0,
                (largest, current) => current > largest ? current : largest,
              );
    final money = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (previous != null && price != null && previous > price)
          Text(
            'EGP ${previous.toStringAsFixed(2)}',
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              color: hubSilver,
              decoration: TextDecoration.lineThrough,
            ),
          ),
        if (price != null)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'EGP ${price.toStringAsFixed(2)}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                color: promotionGold,
                fontSize: 27,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        if (hasClassPrices)
          for (final row in classPrices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${localizedVehicleClass(row)} · ${row['price'] is num ? 'EGP ${(row['price'] as num).toStringAsFixed(2)}' : t('السعر غير محدد لهذه الفئة', 'No price set for this class')}',
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.start,
                style: TextStyle(
                  color: row['price'] is num ? promotionGold : hubSilver,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
      ],
    );
    final hasBooking = offer['service_id'] != null;
    final book = action(
      hasBooking
          ? t('احجز الآن', 'Book now')
          : t('عرض التفاصيل', 'View details'),
      hasBooking ? () => widget.onBookOffer(offer) : widget.onAccount,
      offer: hasBooking,
      icon: hasBooking ? Icons.calendar_month_outlined : Icons.login,
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: hasClassPrices
          ? '${localized(offer, 'name')} · ${classPrices.map((row) => '${localizedVehicleClass(row)} ${row['price'] ?? t('السعر غير متاح', 'price unavailable')}').join(', ')}'
          : '${localized(offer, 'name')}${price == null ? '' : ' · EGP ${price.toStringAsFixed(2)}'}',
      child: Container(
        key: ValueKey('promotion-${offer['offer_id']}'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            colors: [Color(0xFF0D3159), Color(0xFF02182F)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          border: Border.all(color: hubSilver, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(17),
                  ),
                  child: Image.asset(
                    photo(offer),
                    height: 140,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                if (discount > 0)
                  PositionedDirectional(
                    end: 10,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFFE6A1), promotionGold],
                        ),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Text(
                        '${t('خصم', 'Save')}\n$discount%',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: hubNavy,
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      localized(offer, 'name'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Tooltip(
                      message: localized(offer, 'description'),
                      child: Text(
                        localized(offer, 'description'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: hubSilver, fontSize: 14),
                      ),
                    ),
                    if (offer['visits_required'] != null)
                      Text(
                        '${t('الزيارات المطلوبة', 'Required visits')}: ${offer['visits_required']}',
                        style: const TextStyle(color: hubSilver),
                      ),
                    const Spacer(),
                    LayoutBuilder(
                      builder: (_, b) => b.maxWidth > 285 && price != null
                          ? Row(
                              textDirection: TextDirection.ltr,
                              children: [
                                Expanded(child: money),
                                const SizedBox(width: 10),
                                Expanded(child: book),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                money,
                                const SizedBox(height: 8),
                                book,
                              ],
                            ),
                    ),
                    if (offer['service_id'] == null)
                      Text(
                        t(
                          'سجّل الدخول لعرض التفاصيل',
                          'Sign in to view details',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: hubSilver, fontSize: 12),
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

  Widget empty(bool mobile) {
    final message = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          category == 'reward' ? Icons.card_giftcard : Icons.layers_outlined,
          color: hubSilver,
          size: 35,
        ),
        const SizedBox(height: 10),
        Text(
          category == 'limited'
              ? t('لا توجد عروض منشورة حاليًا', 'No published offers right now')
              : category == 'reward'
              ? t(
                  'لا توجد مكافآت منشورة حاليًا',
                  'No published rewards right now',
                )
              : t(
                  'لا توجد باقات منشورة حاليًا',
                  'No published packages right now',
                ),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 23,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 15),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: [
            action(
              t('استكشف الخدمات', 'Explore services'),
              widget.onServices,
              key: const ValueKey('public-services'),
            ),
            action(
              t('احجز الآن', 'Book now'),
              widget.onBooking,
              icon: Icons.calendar_month_outlined,
              key: const ValueKey('public-booking'),
            ),
          ],
        ),
      ],
    );
    return panel(
      mobile
          ? message
          : Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/customer/reference-wash.jpg',
                      height: 175,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(flex: 2, child: message),
              ],
            ),
      padding: EdgeInsets.all(mobile ? 22 : 18),
      image: mobile ? 'assets/customer/reference-premium-car.jpg' : null,
    );
  }

  Widget loyalty() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.emoji_events_outlined,
              color: promotionGold,
              size: 35,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                t('برنامج الولاء', 'Loyalty program'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          widget.points == null
              ? t('سجّل الدخول لعرض رصيدك', 'Sign in to view your balance')
              : '${widget.points} ${t('نقطة', 'points')}',
          style: TextStyle(
            color: widget.points == null ? hubSilver : promotionGold,
            fontSize: widget.points == null ? 17 : 29,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: action(
            t('حسابي ومكافآتي', 'My account & rewards'),
            widget.onAccount,
            icon: Icons.card_giftcard,
          ),
        ),
      ],
    ),
  );
  Widget coupons() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.confirmation_number_outlined,
              color: promotionGold,
              size: 35,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                t('كوبونات الخصم', 'Discount coupons'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (widget.coupons.isEmpty) ...[
          Text(
            t(
              'سجّل الدخول لعرض كوبونات حسابك',
              'Sign in to view your account coupons',
            ),
            style: const TextStyle(color: hubSilver, fontSize: 17),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: action(
              t('دخول العميل', 'Customer sign in'),
              widget.onAccount,
              icon: Icons.login,
            ),
          ),
        ],
        for (final coupon in widget.coupons)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xDD03162D),
                border: Border.all(color: hubSilver),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${coupon['title']}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    coupon['discount_type'] == 'percentage'
                        ? '${coupon['discount_value']}%'
                        : 'EGP ${coupon['discount_value']}',
                    style: const TextStyle(
                      color: promotionGold,
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '${t('الحد الأدنى', 'Minimum')}: EGP ${coupon['minimum_subtotal']}${coupon['max_discount'] == null ? '' : ' · ${t('حد الخصم', 'Cap')}: EGP ${coupon['max_discount']}'}',
                    style: const TextStyle(color: hubSilver),
                  ),
                  if (coupon['first_purchase_only'] == true)
                    Text(
                      t('أول شراء فقط', 'First purchase only'),
                      style: const TextStyle(color: hubSilver),
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: '${coupon['code']}'),
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(t('تم نسخ الكوبون', 'Coupon copied')),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, color: hubSilver),
                    label: Text(
                      '${coupon['code']}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
    image: 'assets/customer/reference-headlight.jpg',
  );
  Widget drawer() => Drawer(
    backgroundColor: Colors.white,
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          brand(145),
          const SizedBox(height: 14),
          for (final item in [
            (t('الرئيسية', 'Home'), home),
            (t('خدماتنا', 'Services'), widget.onServices),
            if (widget.onShop != null) (t('المتجر', 'Shop'), widget.onShop!),
            (t('الحجز', 'Booking'), widget.onBooking),
            (t('الباقات', 'Packages'), () => choose('package', reveal: true)),
            (t('العروض', 'Offers'), () => choose('limited', reveal: true)),
            if (widget.onCareers != null)
              (t('الوظائف المتاحة', 'Careers'), widget.onCareers!),
            (t('تسجيل الدخول', 'Sign in'), widget.onAccount),
          ])
            ListTile(
              key: item.$1 == t('الوظائف المتاحة', 'Careers')
                  ? const ValueKey('public-careers-sidebar')
                  : null,
              title: Text(
                item.$1,
                style: const TextStyle(
                  color: hubNavy,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                item.$2();
              },
            ),
        ],
      ),
    ),
  );
  Widget careersBanner(bool mobile) => Column(
    key: const ValueKey('public-careers-section'),
    children: [
      panel(
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 620;
            final title = Text(
              t('انضم لفريق Sabiha Hub', 'Join the Sabiha Hub Team'),
              key: const ValueKey('public-careers-cta-title'),
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: mobile ? 20 : 25,
              ),
            );
            final button = action(
              t('الوظائف المتاحة', 'View open positions'),
              widget.onCareers,
              icon: Icons.work_outline,
              key: const ValueKey('public-careers-cta'),
            );
            return compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [title, const SizedBox(height: 12), button],
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.groups_2_outlined,
                        size: 38,
                        color: hubSilver,
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: title),
                      const SizedBox(width: 16),
                      button,
                    ],
                  );
          },
        ),
        padding: EdgeInsets.all(mobile ? 16 : 20),
      ),
      const SizedBox(height: 14),
    ],
  );

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: hubNavy,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
    child: Theme(
      data: Theme.of(context).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: hubBlue,
          secondary: hubSilver,
          surface: hubNavy,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final mobile = box.maxWidth < 700,
              compactHeader =
                  box.maxWidth < 1100 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.1,
              headerWidth = box.maxWidth;
          final filtered = widget.offers
              .where((o) => o['category'] == category)
              .toList();
          final cardHeight =
              (mobile ? 460.0 : 410.0) +
              (MediaQuery.textScalerOf(context).scale(16) / 16 - 1).clamp(
                    0,
                    2,
                  ) *
                  230;
          return Scaffold(
            key: scaffold,
            backgroundColor: hubNavy,
            drawer: drawer(),
            bottomNavigationBar: mobile
                ? NavigationBar(
                    height: 72,
                    backgroundColor: const Color(0xFF03162D),
                    indicatorColor: promotionGold,
                    selectedIndex: 3,
                    onDestinationSelected: (i) {
                      if (i == 0) home();
                      if (i == 1) widget.onServices();
                      if (i == 2) widget.onBooking();
                      if (i == 3) choose('limited', reveal: true);
                      if (i == 4) widget.onAccount();
                    },
                    destinations: [
                      NavigationDestination(
                        icon: const Icon(Icons.home_outlined),
                        label: t('الرئيسية', 'Home'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.grid_view_outlined),
                        label: t('الخدمات', 'Services'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: t('الحجز', 'Booking'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.sell_outlined),
                        label: t('العروض', 'Offers'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.person_outline),
                        label: t('حسابي', 'Account'),
                      ),
                    ],
                  )
                : null,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  header(compactHeader, headerWidth),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async => widget.onRetry(),
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment.centerLeft,
                            radius: 1.4,
                            colors: [Color(0xFF0C427B), hubNavy],
                          ),
                        ),
                        child: ListView(
                          controller: scroll,
                          children: [
                            hero(mobile),
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1280,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: mobile ? 12 : 26,
                                    vertical: 12,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      tabs(),
                                      const SizedBox(height: 20),
                                      Row(
                                        key: sectionKey,
                                        children: [
                                          Icon(
                                            category == 'coupon'
                                                ? Icons
                                                      .confirmation_number_outlined
                                                : category == 'reward'
                                                ? Icons.card_giftcard
                                                : Icons.layers_outlined,
                                            color: promotionGold,
                                            size: 30,
                                          ),
                                          const SizedBox(width: 9),
                                          Expanded(
                                            child: Text(
                                              category == 'package'
                                                  ? t(
                                                      'باقات العناية',
                                                      'Care packages',
                                                    )
                                                  : category == 'limited'
                                                  ? t('العروض', 'Offers')
                                                  : category == 'coupon'
                                                  ? t(
                                                      'كوبونات الخصم',
                                                      'Discount coupons',
                                                    )
                                                  : t(
                                                      'مكافآت الولاء',
                                                      'Loyalty rewards',
                                                    ),
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: mobile ? 24 : 28,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 14),
                                      if (widget.loading)
                                        const LinearProgressIndicator(),
                                      if (widget.failed)
                                        panel(
                                          Column(
                                            children: [
                                              Text(
                                                t(
                                                  'تعذر تحميل العروض. أعد المحاولة.',
                                                  'Could not load offers. Please retry.',
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              action(
                                                t('إعادة المحاولة', 'Retry'),
                                                widget.onRetry,
                                                icon: Icons.refresh,
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (!widget.loading &&
                                          !widget.failed) ...[
                                        if (category == 'coupon')
                                          coupons()
                                        else if (filtered.isEmpty)
                                          empty(mobile)
                                        else if (mobile) ...[
                                          SizedBox(
                                            height: cardHeight,
                                            child: Stack(
                                              children: [
                                                PageView.builder(
                                                  controller: pages,
                                                  itemCount: filtered.length,
                                                  onPageChanged: (i) =>
                                                      setState(
                                                        () => pageIndex = i,
                                                      ),
                                                  itemBuilder: (_, i) => Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                        ),
                                                    child: card(filtered[i]),
                                                  ),
                                                ),
                                                if (filtered.length > 1) ...[
                                                  Align(
                                                    alignment:
                                                        AlignmentDirectional
                                                            .centerStart,
                                                    child: IconButton.filledTonal(
                                                      tooltip: t(
                                                        'الباقة السابقة',
                                                        'Previous package',
                                                      ),
                                                      onPressed: pageIndex == 0
                                                          ? null
                                                          : () => pages.previousPage(
                                                              duration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        220,
                                                                  ),
                                                              curve: Curves
                                                                  .easeOut,
                                                            ),
                                                      icon: const Icon(
                                                        Icons.chevron_left,
                                                      ),
                                                    ),
                                                  ),
                                                  Align(
                                                    alignment:
                                                        AlignmentDirectional
                                                            .centerEnd,
                                                    child: IconButton.filledTonal(
                                                      tooltip: t(
                                                        'الباقة التالية',
                                                        'Next package',
                                                      ),
                                                      onPressed:
                                                          pageIndex ==
                                                              filtered.length -
                                                                  1
                                                          ? null
                                                          : () => pages.nextPage(
                                                              duration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        220,
                                                                  ),
                                                              curve: Curves
                                                                  .easeOut,
                                                            ),
                                                      icon: const Icon(
                                                        Icons.chevron_right,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              for (
                                                var i = 0;
                                                i < filtered.length;
                                                i++
                                              )
                                                Padding(
                                                  padding: const EdgeInsets.all(
                                                    5,
                                                  ),
                                                  child: Icon(
                                                    Icons.circle,
                                                    size: 7,
                                                    color: i == pageIndex
                                                        ? promotionGold
                                                        : hubBlue,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ] else
                                          LayoutBuilder(
                                            builder: (_, b) {
                                              final columns = b.maxWidth >= 1000
                                                  ? 3
                                                  : 2;
                                              final width =
                                                  (b.maxWidth -
                                                      (columns - 1) * 14) /
                                                  columns;
                                              return Wrap(
                                                spacing: 14,
                                                runSpacing: 14,
                                                children: [
                                                  for (final o in filtered)
                                                    SizedBox(
                                                      width: width,
                                                      height: cardHeight,
                                                      child: card(o),
                                                    ),
                                                ],
                                              );
                                            },
                                          ),
                                      ],
                                      const SizedBox(height: 18),
                                      LayoutBuilder(
                                        builder: (_, b) => b.maxWidth < 760
                                            ? Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  loyalty(),
                                                  const SizedBox(height: 14),
                                                  if (category != 'coupon')
                                                    coupons(),
                                                ],
                                              )
                                            : Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Expanded(child: loyalty()),
                                                  const SizedBox(width: 16),
                                                  Expanded(child: coupons()),
                                                ],
                                              ),
                                      ),
                                      if (widget.isLanding &&
                                          widget.onCareers != null)
                                        careersBanner(mobile),
                                      if (widget.onStaff != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 18,
                                          ),
                                          child: Center(
                                            child: TextButton.icon(
                                              key: const ValueKey(
                                                'public-staff-footer',
                                              ),
                                              onPressed: widget.onStaff,
                                              icon: const Icon(
                                                Icons.badge_outlined,
                                                color: hubSilver,
                                              ),
                                              label: Text(
                                                t(
                                                  'دخول الموظفين',
                                                  'Staff sign in',
                                                ),
                                                style: const TextStyle(
                                                  color: hubSilver,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (widget.support != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 12,
                                          ),
                                          child: widget.support!,
                                        ),
                                      const SizedBox(height: 12),
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
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _OfferRibbon extends CustomPainter {
  const _OfferRibbon();
  @override
  void paint(Canvas canvas, Size size) {
    final ribbon = Path()
      ..moveTo(size.width * .36, size.height)
      ..cubicTo(
        size.width * .6,
        -size.height * .6,
        size.width * .73,
        -size.height * .5,
        size.width,
        size.height,
      )
      ..lineTo(size.width, size.height * .5)
      ..cubicTo(
        size.width * .75,
        -size.height * .9,
        size.width * .58,
        -size.height * .55,
        size.width * .36,
        size.height,
      )
      ..close();
    canvas.drawPath(
      ribbon,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFF795011),
            Color(0xFFFFE9AE),
            promotionGold,
            Color(0xFF806018),
          ],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_OfferRibbon oldDelegate) => false;
}
