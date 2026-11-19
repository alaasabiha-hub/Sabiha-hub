import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:async';

enum CustomerSessionStatus { authorized, signedOut, notCustomer, unavailable }

class CustomerSessionCheck {
  final CustomerSessionStatus status;
  final String? userId;

  const CustomerSessionCheck(this.status, {this.userId});
}

abstract interface class CustomerSessionGateway {
  Future<CustomerSessionCheck> verify();
  Stream<Object?>? get changes;
}

class SupabaseCustomerSessionGateway implements CustomerSessionGateway {
  final SupabaseClient client;
  final Future<void> Function()? beforeLocalSignOut;

  const SupabaseCustomerSessionGateway(this.client, {this.beforeLocalSignOut});

  @override
  Stream<Object?> get changes =>
      client.auth.onAuthStateChange.map((event) => event.event);

  @override
  Future<CustomerSessionCheck> verify() async {
    final session = client.auth.currentSession;
    if (session == null) {
      return const CustomerSessionCheck(CustomerSessionStatus.signedOut);
    }
    try {
      final response = await client.auth.getUser().timeout(
        const Duration(seconds: 8),
      );
      final user = response.user;
      if (user == null || user.id != session.user.id) {
        return const CustomerSessionCheck(CustomerSessionStatus.signedOut);
      }

      final staff = await client
          .from('staff_profiles')
          .select('user_id,is_active')
          .eq('user_id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (staff?['is_active'] == true) {
        return const CustomerSessionCheck(CustomerSessionStatus.notCustomer);
      }

      final customer = await client
          .from('customers')
          .select('id')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (customer == null || customer['id'] != user.id) {
        return const CustomerSessionCheck(CustomerSessionStatus.notCustomer);
      }
      return CustomerSessionCheck(
        CustomerSessionStatus.authorized,
        userId: user.id,
      );
    } on AuthException catch (error) {
      if (error.statusCode == '401' || error.statusCode == '403') {
        try {
          await beforeLocalSignOut?.call();
          await client.auth.signOut(scope: SignOutScope.local);
        } catch (_) {}
        return const CustomerSessionCheck(CustomerSessionStatus.signedOut);
      }
      return const CustomerSessionCheck(CustomerSessionStatus.unavailable);
    } catch (_) {
      // A network error must not be mistaken for a signed-out session.
      return const CustomerSessionCheck(CustomerSessionStatus.unavailable);
    }
  }
}

class CustomerSessionGuard extends StatefulWidget {
  final CustomerSessionGateway gateway;
  final Widget child;
  final WidgetBuilder loginBuilder;
  final WidgetBuilder notCustomerBuilder;

  const CustomerSessionGuard({
    super.key,
    required this.gateway,
    required this.child,
    required this.loginBuilder,
    required this.notCustomerBuilder,
  });

  @override
  State<CustomerSessionGuard> createState() => _CustomerSessionGuardState();
}

class _CustomerSessionGuardState extends State<CustomerSessionGuard>
    with WidgetsBindingObserver {
  late Future<CustomerSessionCheck> _check;
  StreamSubscription<Object?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check = widget.gateway.verify();
    _authSubscription = widget.gateway.changes?.listen((_) {
      if (mounted) _retry();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _retry();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _check = widget.gateway.verify();
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CustomerSessionCheck>(
    future: _check,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) return _unavailable(context);
      return switch (snapshot.data?.status) {
        CustomerSessionStatus.authorized => widget.child,
        CustomerSessionStatus.signedOut => widget.loginBuilder(context),
        CustomerSessionStatus.notCustomer => widget.notCustomerBuilder(context),
        CustomerSessionStatus.unavailable || null => _unavailable(context),
      };
    },
  );

  Widget _unavailable(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            Localizations.localeOf(context).languageCode == 'ar'
                ? 'تعذر التحقق من الجلسة الآن. تحقق من الاتصال وأعد المحاولة.'
                : 'Could not verify the session. Check the connection and retry.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _retry,
            child: Text(
              Localizations.localeOf(context).languageCode == 'ar'
                  ? 'إعادة المحاولة'
                  : 'Retry',
            ),
          ),
        ],
      ),
    ),
  );
}
