import 'package:flutter/material.dart';

import 'offers_catalog.dart';
import 'catalog_refresh.dart';

/// The public entry point loads the existing published-only Supabase contract.
/// It never creates sample packages, coupons, prices, or loyalty balances.
class PublicLandingScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() loadOffers;
  final VoidCallback onServices, onBooking, onAccount, onStaff, onLanguage;
  final VoidCallback? onShop;
  final ValueChanged<Map<String, dynamic>> onBookOffer;
  final Widget? support;
  final VoidCallback? onCareers;
  const PublicLandingScreen({
    super.key,
    required this.loadOffers,
    required this.onServices,
    required this.onBooking,
    required this.onAccount,
    required this.onStaff,
    required this.onLanguage,
    required this.onBookOffer,
    this.support,
    this.onCareers,
    this.onShop,
  });

  @override
  State<PublicLandingScreen> createState() => _PublicLandingScreenState();
}

class _PublicLandingScreenState extends State<PublicLandingScreen> {
  List<Map<String, dynamic>> offers = [];
  bool loading = true, failed = false;
  CatalogRefresh? refresh;
  @override
  void initState() {
    super.initState();
    load();
    refresh = CatalogRefresh(
      refresh: () => load(quiet: true),
      allowed: () =>
          mounted && !loading && (ModalRoute.of(context)?.isCurrent ?? true),
    );
  }

  @override
  void dispose() {
    refresh?.dispose();
    super.dispose();
  }

  Future<void> load({bool quiet = false}) async {
    setState(() {
      loading = !quiet;
      failed = false;
    });
    try {
      final result = await widget.loadOffers();
      final published = List<Map<String, dynamic>>.from(
        result['offers'] as List,
      );
      if (mounted) {
        setState(() {
          offers = published;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          offers = [];
          loading = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => OffersCatalogPage(
    offers: offers,
    coupons: const [],
    points: null,
    loading: loading,
    failed: failed,
    onRetry: load,
    onHome: () {},
    isLanding: true,
    onServices: widget.onServices,
    onBooking: widget.onBooking,
    onAccount: widget.onAccount,
    onStaff: widget.onStaff,
    onCareers: widget.onCareers,
    onShop: widget.onShop,
    support: widget.support,
    onLanguage: widget.onLanguage,
    onBookOffer: widget.onBookOffer,
    // Guest-specific coupons and loyalty require authentication, not made-up data.
    localDevelopment: false,
  );
}
