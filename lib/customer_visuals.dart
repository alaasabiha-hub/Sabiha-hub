import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'home_tagline.dart';

import 'welcome_ui.dart';

const customerBlack = Color(0xff020b14),
    customerNavy = Color(0xff051b34),
    customerBlue = Color(0xff1765ad),
    customerGold = Color(0xffffd34d),
    customerIce = Color(0xffa6c8e7);
bool customerArabic(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'ar';
String customerText(BuildContext c, String ar, String en) =>
    customerArabic(c) ? ar : en;
ThemeData customerTheme(BuildContext context) => Theme.of(context).copyWith(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: customerBlack,
  canvasColor: customerNavy,
  colorScheme: const ColorScheme.dark(
    primary: customerGold,
    secondary: customerBlue,
    surface: customerNavy,
    onSurface: Colors.white,
    onPrimary: customerBlack,
  ),
  textTheme: Theme.of(context).textTheme
      .apply(bodyColor: Colors.white, displayColor: Colors.white),
  appBarTheme: const AppBarTheme(
    backgroundColor: customerBlack,
    foregroundColor: Colors.white,
  ),
  cardTheme: CardThemeData(
    color: customerNavy,
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: customerBlue),
    ),
  ),
  iconTheme: const IconThemeData(color: customerGold),
  dividerColor: customerBlue.withValues(alpha: .5),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xff0b2540),
    hintStyle: const TextStyle(color: customerIce),
    labelStyle: const TextStyle(color: customerIce),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: customerBlue),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: customerBlue),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: customerGold, width: 1.5),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: customerGold,
      side: const BorderSide(color: customerGold),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: customerGold,
      foregroundColor: customerBlack,
      minimumSize: const Size(48, 48),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: customerGold,
      foregroundColor: customerBlack,
      minimumSize: const Size(48, 46),
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: customerNavy,
    selectedColor: customerGold,
    labelStyle: const TextStyle(color: Colors.white),
    secondaryLabelStyle: const TextStyle(color: customerBlack),
    side: const BorderSide(color: customerBlue),
  ),
  listTileTheme: const ListTileThemeData(
    textColor: Colors.white,
    iconColor: customerGold,
  ),
);

String customerServicePhoto(String title) {
  final value = title.toLowerCase();
  if (RegExp('polish|ceramic|protect|تلميع|حماية|سيراميك').hasMatch(value)) {
    return 'assets/customer/polish.jpg';
  }
  if (RegExp('inspect|فحص|صيانة|mechanic').hasMatch(value)) {
    return 'assets/customer/inspection.jpg';
  }
  return 'assets/customer/wash.jpg';
}

class CustomerPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const CustomerPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: padding,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff193b5c), Color(0xff031729), Color(0xff010912)],
      ),
      borderRadius: BorderRadius.circular(21),
      border: Border.all(color: const Color(0xff438dcd)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33176ac1),
          blurRadius: 12,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: child,
  );
}

class GoldButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  const GoldButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.arrow_forward,
  });
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xffffec9b), Color(0xffffc400), Color(0xffb97a00)],
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: customerGold),
      boxShadow: const [BoxShadow(color: Color(0x55ffce46), blurRadius: 12)],
    ),
    child: TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: customerBlack),
      label: Text(
        label,
        style: const TextStyle(
          color: customerBlack,
          fontWeight: FontWeight.w800,
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
  );
}

class GoldWave extends CustomPainter {
  const GoldWave();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height * .88)
      ..cubicTo(
        size.width * .3,
        -size.height * .2,
        size.width * .61,
        size.height * 1.2,
        size.width,
        size.height * .2,
      );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..shader = const LinearGradient(
          colors: [Color(0xffad7400), Color(0xffffec8a), Color(0xffffc800)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class CustomerHero extends StatelessWidget {
  final bool showHomeTagline;
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onMenu;
  final VoidCallback? onNotifications;
  final Widget? notificationAction;
  const CustomerHero({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onMenu,
    this.onNotifications,
    this.notificationAction,
    this.showHomeTagline = false,
    this.icon = Icons.calendar_month_outlined,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: showHomeTagline
            ? 230 +
                  (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(0, 2) *
                      120
            : 155,
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/customer/night-car.jpg',
                fit: BoxFit.cover,
                alignment: Alignment.centerLeft,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      customerBlack.withValues(alpha: .35),
                      customerBlack.withValues(alpha: .95),
                      customerNavy,
                    ],
                    stops: const [0, .52, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                onPressed: onMenu,
                icon: const Icon(Icons.menu, color: Colors.white),
                tooltip: customerText(context, 'القائمة', 'Menu'),
              ),
            ),
            if (onNotifications != null || notificationAction != null)
              Positioned(
                top: 4,
                right: 4,
                child:
                    notificationAction ??
                    IconButton(
                      onPressed: onNotifications,
                      icon: const Icon(
                        Icons.notifications_none,
                        color: Colors.white,
                      ),
                      tooltip: customerText(
                        context,
                        'تحديثات الطلبات',
                        'Order updates',
                      ),
                    ),
              ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const OriginalHubMark(size: 62),
                  const Text(
                    'Sabiha Hub',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  const Text(
                    'مفهوم جديد للعناية المتكاملة',
                    style: TextStyle(fontSize: 10, color: Colors.white),
                  ),
                  const Text(
                    'A New Concept in Total Care',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(fontSize: 10, color: Colors.white),
                  ),
                  if (showHomeTagline)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: HomeTagline(onDark: true),
                    ),
                ],
              ),
            ),
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 25,
              child: CustomPaint(painter: GoldWave()),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
        child: Row(
          children: [
            Icon(icon, size: 32, color: customerGold),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: const TextStyle(color: customerIce, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class CustomerShell extends StatelessWidget {
  final bool showHomeTagline;
  final String title, subtitle;
  final Widget body;
  final IconData icon;
  final int selected;
  final ValueChanged<int> onNavigate;
  final List<Widget> menuExtras;
  final VoidCallback? onNotifications;
  final Widget? notificationAction;
  final Widget? actions;
  final Widget? floatingActionButton;
  const CustomerShell({
    super.key,
    required this.title,
    required this.body,
    required this.onNavigate,
    this.subtitle = '',
    this.icon = Icons.directions_car_outlined,
    this.selected = 0,
    this.menuExtras = const [],
    this.onNotifications,
    this.notificationAction,
    this.actions,
    this.floatingActionButton,
    this.showHomeTagline = false,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => kIsWeb && constraints.maxWidth >= 900
        ? _buildDesktop(context)
        : _buildMobile(context),
  );

  Widget _buildDesktop(BuildContext context) => Theme(
    data: customerTheme(context),
    child: Builder(
      builder: (context) => Scaffold(
        backgroundColor: customerBlack,
        floatingActionButton: floatingActionButton,
        drawer: Drawer(
          backgroundColor: customerNavy,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const Center(child: OriginalHubMark(size: 80)),
                const Center(
                  child: Text(
                    'Sabiha Hub',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 20),
                for (var i = 0; i < 5; i++)
                  ListTile(
                    leading: Icon(_icons[i]),
                    title: Text(customerText(context, _ar[i], _en[i])),
                    onTap: () {
                      Navigator.pop(context);
                      onNavigate(i);
                    },
                  ),
                ...menuExtras,
              ],
            ),
          ),
        ),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(82),
          child: Material(
            color: Colors.white,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 150,
                      height: 66,
                      child: Image.asset(
                        approvedBrandAsset,
                        fit: BoxFit.contain,
                        semanticLabel: 'Sabiha Hub',
                      ),
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 4,
                        children: [
                          for (var i = 0; i < 5; i++)
                            TextButton.icon(
                              onPressed: () => onNavigate(i),
                              icon: Icon(_icons[i], size: 19),
                              label: Text(
                                customerText(context, _ar[i], _en[i]),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: i == selected
                                    ? customerBlue
                                    : customerNavy,
                                backgroundColor: i == selected
                                    ? const Color(0xFFEAF1F8)
                                    : Colors.transparent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 13,
                                  vertical: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: CustomerRoutes.toggleLanguage,
                      child: Text(
                        Localizations.localeOf(context).languageCode == 'ar'
                            ? 'EN'
                            : 'العربية',
                      ),
                    ),
                    ?notificationAction,
                    ?actions,
                    Builder(
                      builder: (c) => IconButton(
                        tooltip: customerText(context, 'القائمة', 'Menu'),
                        onPressed: () => Scaffold.of(c).openDrawer(),
                        icon: const Icon(Icons.menu, color: customerNavy),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(24, 18, 24, 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 22,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF123B70), customerNavy],
                  ),
                  border: Border.all(color: customerBlue),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  textDirection: TextDirection.rtl,
                  children: [
                    Icon(icon, color: customerGold, size: 34),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 25,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              style: const TextStyle(color: customerIce),
                            ),
                          if (showHomeTagline)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: HomeTagline(onDark: true),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1360),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: body,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildMobile(BuildContext context) => Theme(
    data: customerTheme(context),
    child: Builder(
      builder: (context) => Scaffold(
        backgroundColor: customerBlack,
        floatingActionButton: floatingActionButton,
        drawer: Drawer(
          backgroundColor: customerNavy,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const Center(child: OriginalHubMark(size: 80)),
                const Center(
                  child: Text(
                    'Sabiha Hub',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 20),
                for (var i = 0; i < 5; i++)
                  ListTile(
                    leading: Icon(_icons[i]),
                    title: Text(customerText(context, _ar[i], _en[i])),
                    onTap: () {
                      Navigator.pop(context);
                      onNavigate(i);
                    },
                  ),
                ...menuExtras,
              ],
            ),
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Builder(
                        builder: (c) => CustomerHero(
                          showHomeTagline: showHomeTagline,
                          title: title,
                          subtitle: subtitle,
                          icon: icon,
                          onMenu: () => Scaffold.of(c).openDrawer(),
                          onNotifications: onNotifications,
                          notificationAction: notificationAction,
                        ),
                      ),
                    ),
                    if (actions != null) SliverToBoxAdapter(child: actions!),
                    SliverFillRemaining(hasScrollBody: true, child: body),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 7, 12, 8),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xff1b3b5f), customerBlack],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              border: Border.all(color: customerBlue),
              borderRadius: BorderRadius.circular(27),
            ),
            child: Row(
              children: [
                for (var i = 0; i < 5; i++)
                  Expanded(
                    child: Semantics(
                      selected: i == selected,
                      button: true,
                      label: customerText(context, _ar[i], _en[i]),
                      child: InkWell(
                        onTap: () => onNavigate(i),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: i == selected
                                ? Border.all(color: customerGold)
                                : null,
                            gradient: i == selected
                                ? const LinearGradient(
                                    colors: [
                                      Color(0xff715100),
                                      Color(0xff181b1a),
                                    ],
                                  )
                                : null,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _icons[i],
                                color: i == selected
                                    ? customerGold
                                    : Colors.white,
                                size: 24,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                customerText(context, _ar[i], _en[i]),
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: i == selected
                                      ? customerGold
                                      : Colors.white,
                                ),
                              ),
                            ],
                          ),
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
  );
  static const _icons = [
    Icons.home_outlined,
    Icons.grid_view_outlined,
    Icons.calendar_month_outlined,
    Icons.shopping_cart_outlined,
    Icons.person_outline,
  ];
  static const _ar = ['الرئيسية', 'الخدمات', 'حجوزاتي', 'المتجر', 'حسابي'];
  static const _en = ['Home', 'Services', 'Bookings', 'Shop', 'Profile'];
}

class CustomerActionTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool gold;
  const CustomerActionTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.gold = false,
  });
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(18),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 19, horizontal: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: gold ? customerGold : customerBlue),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gold
              ? const [Color(0xff544318), customerBlack]
              : const [Color(0xff153e66), customerBlack],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: gold ? customerGold : Colors.white, size: 30),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}

String customerCatalogText(
  BuildContext context,
  Map<String, dynamic> item,
  String field,
) {
  final translated = item['${field}_en']?.toString().trim();
  return customerText(
    context,
    '${item[field] ?? ''}',
    translated == null || translated.isEmpty
        ? '${item[field] ?? ''}'
        : translated,
  );
}

class CustomerCatalogPhoto extends StatelessWidget {
  const CustomerCatalogPhoto({
    super.key,
    required this.item,
    required this.height,
  });
  final Map<String, dynamic> item;
  final double height;
  @override
  Widget build(BuildContext context) {
    Widget fallback() => Image.asset(
      customerServicePhoto('${item['name']}'),
      height: height,
      fit: BoxFit.cover,
      semanticLabel: customerText(
        context,
        'صورة توضيحية لخدمات السيارات',
        'Illustrative car care photo',
      ),
    );
    final url = item['image_display_url'];
    return url is String && url.isNotEmpty
        ? Image.network(
            url,
            height: height,
            fit: BoxFit.cover,
            cacheWidth: 320,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : fallback(),
            semanticLabel: customerText(
              context,
              'صورة الخدمة',
              'Service photo',
            ),
            errorBuilder: (_, error, stack) => fallback(),
          )
        : fallback();
  }
}

class CustomerServiceTile extends StatelessWidget {
  final Map<String, dynamic> service;
  final VoidCallback onBook;
  final bool compareSelected;
  final ValueChanged<bool>? onCompare;
  const CustomerServiceTile({
    super.key,
    required this.service,
    required this.onBook,
    this.compareSelected = false,
    this.onCompare,
  });
  @override
  Widget build(BuildContext context) {
    final desktop = kIsWeb && MediaQuery.sizeOf(context).width >= 900;
    if (desktop) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFC5CBD5)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14071A36),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CustomerCatalogPhoto(item: service, height: 170),
            ),
            const SizedBox(height: 14),
            Text(
              customerCatalogText(context, service, 'name'),
              style: const TextStyle(
                color: Color(0xFF071A36),
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (customerCatalogText(context, service, 'description').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  customerCatalogText(context, service, 'description'),
                  style: const TextStyle(color: Color(0xFF526579)),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 8,
              children: [
                CustomerVehicleClassPriceList(service: service, desktop: true),
                if (service['duration_minutes'] != null)
                  Text(
                    '${service['duration_minutes']} ${customerText(context, 'دقيقة', 'min')}',
                    style: const TextStyle(color: Color(0xFF526579)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onBook,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(customerText(context, 'احجز الآن', 'Book now')),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF174B83),
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 48),
              ),
            ),
            if (onCompare != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: compareSelected,
                onChanged: (v) => onCompare!(v == true),
                title: Text(
                  customerText(context, 'أضف للمقارنة', 'Compare service'),
                  style: const TextStyle(color: Color(0xFF071A36)),
                ),
                activeColor: const Color(0xFF174B83),
                checkColor: Colors.white,
              ),
          ],
        ),
      );
    }
    return CustomerPanel(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: CustomerCatalogPhoto(item: service, height: 145),
          ),
          const SizedBox(height: 12),
          Text(
            customerCatalogText(context, service, 'name'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (customerCatalogText(context, service, 'description').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                customerCatalogText(context, service, 'description'),
                style: const TextStyle(color: customerIce),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 8,
            children: [
              CustomerVehicleClassPriceList(service: service),
              if (service['duration_minutes'] != null)
                Text(
                  '${service['duration_minutes']} ${customerText(context, 'دقيقة', 'min')}',
                  style: const TextStyle(color: Colors.white),
                ),
            ],
          ),
          const SizedBox(height: 12),
          GoldButton(
            label: customerText(context, 'احجز الآن', 'Book now'),
            icon: Icons.calendar_month_outlined,
            onPressed: onBook,
          ),
          if (onCompare != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: compareSelected,
              onChanged: (v) => onCompare!(v == true),
              title: Text(
                customerText(context, 'أضف للمقارنة', 'Compare service'),
                style: const TextStyle(color: customerIce),
              ),
              activeColor: customerGold,
              checkColor: customerBlack,
            ),
        ],
      ),
    );
  }
}

/// Public service prices are always shown by vehicle class. The legacy flat
/// catalogue price is intentionally ignored so the public card agrees with
/// the server quote required at booking and cashier checkout.
class CustomerVehicleClassPriceList extends StatelessWidget {
  const CustomerVehicleClassPriceList({
    super.key,
    required this.service,
    this.desktop = false,
  });

  final Map<String, dynamic> service;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final isArabic = customerArabic(context);
    final raw = service['vehicle_class_prices'];
    final rows = raw is List
        ? raw.whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList()
        : <Map<String, dynamic>>[];
    final foreground = desktop ? const Color(0xFF071A36) : Colors.white;
    final muted = desktop ? const Color(0xFF526579) : customerIce;

    if (rows.isEmpty) {
      return Text(
        customerText(context, 'اختر فئة السيارة لمعرفة السعر', 'Select a vehicle class to see the price'),
        style: TextStyle(color: muted, fontSize: 14, fontWeight: FontWeight.w700),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final row in rows)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: desktop ? const Color(0xFFF2F6FB) : customerNavy,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: desktop ? const Color(0xFFC5CBD5) : customerBlue,
              ),
            ),
            child: Text(
              '${_className(row, isArabic)} · ${_classPrice(context, row)}',
              textDirection: TextDirection.rtl,
              style: TextStyle(
                color: row['price'] is num ? foreground : muted,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    );
  }

  String _className(Map<String, dynamic> row, bool isArabic) {
    final preferred = row[isArabic ? 'name_ar' : 'name_en'];
    final fallback = row[isArabic ? 'name_en' : 'name_ar'];
    final value = preferred ?? fallback ?? row['class_code'];
    return value?.toString().trim().isNotEmpty == true
        ? value.toString().trim()
        : (isArabic ? 'فئة السيارة' : 'Vehicle class');
  }

  String _classPrice(BuildContext context, Map<String, dynamic> row) {
    final value = row['price'];
    if (value is num && value.isFinite && value >= 0) {
      return customerText(
        context,
        '${value.toStringAsFixed(2)} ج.م',
        'EGP ${value.toStringAsFixed(2)}',
      );
    }
    return customerText(context, 'السعر غير متاح', 'Price unavailable');
  }
}

/// Registered once by the application; shared feature libraries keep their existing data clients.
class CustomerRoutes {
  static void Function(BuildContext, int)? navigate;
  static List<Widget> Function(BuildContext)? menu;
  static VoidCallback? toggleLanguage;
}

class CustomerAdaptiveFrame extends StatelessWidget {
  final bool enabled;
  final String title, subtitle;
  final Widget body;
  final AppBar? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final int selected;
  const CustomerAdaptiveFrame({
    super.key,
    this.enabled = true,
    required this.title,
    this.subtitle = '',
    required this.body,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.selected = 4,
  });
  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return Scaffold(
        appBar: appBar,
        body: body,
        bottomNavigationBar: bottomNavigationBar,
        floatingActionButton: floatingActionButton,
      );
    }
    return CustomerShell(
      title: title,
      subtitle: subtitle,
      floatingActionButton: floatingActionButton,
      selected: selected,
      onNavigate: (i) {
        final handler = CustomerRoutes.navigate;
        if (handler != null) {
          handler(context, i);
        } else {
          Navigator.maybePop(context);
        }
      },
      menuExtras: CustomerRoutes.menu?.call(context) ?? [],
      actions: appBar?.actions == null
          ? null
          : Wrap(children: appBar!.actions!),
      body: bottomNavigationBar == null
          ? body
          : Column(
              children: [
                Expanded(child: body),
                bottomNavigationBar!,
              ],
            ),
    );
  }
}

int customerServiceOrder(Map<String, dynamic> service) {
  final name = '${service['name']}'.toLowerCase();
  if (RegExp('wash|غسيل').hasMatch(name)) return 0;
  if (RegExp('polish|تلميع').hasMatch(name)) return 1;
  return 2;
}

Future<T?> showCustomerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (c) => Theme(
    data: customerTheme(c),
    child: Builder(builder: builder),
  ),
);
Future<DateTime?> showCustomerDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) => showDatePicker(
  context: context,
  initialDate: initialDate,
  firstDate: firstDate,
  lastDate: lastDate,
  builder: (c, child) => Theme(data: customerTheme(c), child: child!),
);
