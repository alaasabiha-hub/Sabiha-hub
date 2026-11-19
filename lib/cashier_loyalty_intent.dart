import 'dart:async';

import 'cashier_invoice_draft.dart' show CashierCartGateway;
import 'workflow.dart' show newOrderRequestId;

/// A version-bound base seal, never a wallet, customer consent or spending right.
/// A later reward proposal must include its own exact allocations and consent.
class CashierLoyaltyDraftSeal {
  CashierLoyaltyDraftSeal({
    required this.gateway,
    required this.branch,
    required this.draft,
    required this.draftVersion,
    required this.bindingVersion,
  }) {
    if (branch.isEmpty ||
        draft.isEmpty ||
        draftVersion < 1 ||
        bindingVersion < 1) {
      throw ArgumentError('A saved, explicitly bound draft is required');
    }
    _changes = gateway.changes.listen((_) => dispose());
  }
  final CashierCartGateway gateway;
  final String branch, draft;
  final int draftVersion, bindingVersion;
  StreamSubscription<void>? _changes;
  Map<String, dynamic>? _pending;
  Future<Map<String, dynamic>>? _inflight;
  bool _disposed = false;
  bool get current => !_disposed && gateway.current;

  void _requireCurrent() {
    if (!current) throw StateError('Cashier identity changed');
  }

  Future<Map<String, dynamic>> prepare() {
    _requireCurrent();
    return _inflight ??= _prepare().whenComplete(() => _inflight = null);
  }

  Future<Map<String, dynamic>> _prepare() async {
    _pending ??= Map.unmodifiable({
      'p_request': newOrderRequestId(),
      'p_branch': branch,
      'p_draft': draft,
      'p_expected_draft_version': draftVersion,
      'p_expected_binding_version': bindingVersion,
    });
    // Retain this exact nonce and version after an uncertain response.
    final result = await gateway.call('seal_cashier_loyalty_draft', _pending!);
    _requireCurrent();
    _validate(result);
    return Map.unmodifiable(result);
  }

  Future<Map<String, dynamic>> refresh() async {
    _requireCurrent();
    if (_pending == null) throw StateError('No seal request to recover');
    final result = await gateway.call('get_cashier_loyalty_draft_intent', {
      'p_branch': branch,
      'p_request': _pending!['p_request'],
    });
    _requireCurrent();
    _validate(result);
    if (!const {'current', 'stale', 'expired'}.contains(result['state']) ||
        result['wallet_disclosed'] != false) {
      throw StateError('Invalid base-seal state');
    }
    return Map.unmodifiable(result);
  }

  void _validate(Map<String, dynamic> result) {
    if (result['intent_id'] != _pending!['p_request'] ||
        result['seal_only'] != true ||
        result['consent_authorized'] != false ||
        result['redemption_enabled'] != false ||
        result['fingerprint'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(result['fingerprint']) ||
        result['expires_at'] is! String ||
        DateTime.tryParse(result['expires_at']) == null) {
      throw StateError('Invalid base-seal receipt');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending = null;
    unawaited(_changes?.cancel());
    _changes = null;
  }
}
