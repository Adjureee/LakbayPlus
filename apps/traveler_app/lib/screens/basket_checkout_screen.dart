import 'package:flutter/material.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

class BasketCheckoutScreen extends StatefulWidget {
  final TravelRepository repo;

  const BasketCheckoutScreen({super.key, required this.repo});

  @override
  State<BasketCheckoutScreen> createState() => _BasketCheckoutScreenState();
}

class _BasketCheckoutScreenState extends State<BasketCheckoutScreen> {
  String _selectedPaymentMethod = 'shop_pay';
  bool _isProcessing = false;
  bool _showPast = false;

  void _openExpressCheckoutSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final totalFormatted =
              widget.repo.formatPrice(widget.repo.basketTotalUsd);
          return Padding(
            padding: EdgeInsets.only(
              left: 22,
              right: 22,
              top: 22,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_rounded,
                        color: LakbayColors.tealAccent, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Lakbay+ Express Checkout',
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const Text(
                  'Instant confirmation • Free 24h cancellation included',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),
                // Express Checkout Payment Method Selector (matching index.html: card, link, shop_pay)
                _buildPaymentOptionTile(
                  id: 'shop_pay',
                  title: 'Express Pay (1-Tap Wallet)',
                  subtitle: 'Fastest checkout with saved traveler profile',
                  icon: Icons.flash_on_rounded,
                  selected: _selectedPaymentMethod == 'shop_pay',
                  onTap: () =>
                      setSheetState(() => _selectedPaymentMethod = 'shop_pay'),
                ),
                const SizedBox(height: 10),
                _buildPaymentOptionTile(
                  id: 'link',
                  title: 'Stripe Link Instant Pay',
                  subtitle: 'Auto-fill card & billing details securely',
                  icon: Icons.account_balance_wallet_rounded,
                  selected: _selectedPaymentMethod == 'link',
                  onTap: () =>
                      setSheetState(() => _selectedPaymentMethod = 'link'),
                ),
                const SizedBox(height: 10),
                _buildPaymentOptionTile(
                  id: 'card',
                  title: 'Credit / Debit Card',
                  subtitle: 'Visa, Mastercard, Amex • 0% FX fee',
                  icon: Icons.credit_card_rounded,
                  selected: _selectedPaymentMethod == 'card',
                  onTap: () =>
                      setSheetState(() => _selectedPaymentMethod = 'card'),
                ),
                const Divider(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total Due Today',
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      totalFormatted,
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () async {
                            setSheetState(() => _isProcessing = true);
                            final reservation = await widget.repo
                                .recordReservationCheckout(
                              paymentMethod: _selectedPaymentMethod,
                            );
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
                            setState(() => _isProcessing = false);
                            if (!mounted) return;
                            _showConfirmationDialog(
                              totalFormatted,
                              syncedToCloud: reservation.syncedToCloud,
                            );
                          },
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.verified_user_rounded),
                    label: Text(
                      _isProcessing
                          ? 'Confirming Reservation...'
                          : 'Confirm & Pay $totalFormatted',
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showConfirmationDialog(
    String amountPaid, {
    bool syncedToCloud = false,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded,
                color: LakbayColors.successGreen, size: 28),
            SizedBox(width: 10),
            Text(
              'Trip Reserved!',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: Text(
          syncedToCloud
              ? 'Your reservation ($amountPaid) is recorded and synced to your Lakbay+ cloud trips!'
              : 'Your reservation ($amountPaid) is saved on this device! Sign in anytime to sync reservations to your cloud account.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: LakbayColors.primary,
            ),
            child: const Text('Awesome'),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentOptionTile({
    required String id,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? LakbayColors.primarySoft : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color:
                selected ? LakbayColors.primary : LakbayColors.cardBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: selected
                    ? LakbayColors.primary
                    : LakbayColors.tealDeep),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: selected
                  ? LakbayColors.primary
                  : LakbayColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.repo.basket;

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      appBar: AppBar(
        backgroundColor: LakbayColors.canvasBg,
        elevation: 0,
        title: const Text(
          'Bookings',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w800,
            fontSize: 28,
            color: LakbayColors.tealDeep,
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 14, top: 8, bottom: 8),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SegmentPill(
                  label: 'Upcoming',
                  selected: !_showPast,
                  onTap: () => setState(() => _showPast = false),
                ),
                _SegmentPill(
                  label: 'Past',
                  selected: _showPast,
                  onTap: () => setState(() => _showPast = true),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _showPast
          ? (widget.repo.bookings.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 32, 32, 110),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                            color: LakbayColors.primaryLight,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            'L✦',
                            style: TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: LakbayColors.primaryDark,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'No recorded reservations yet',
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w800,
                            fontSize: 21,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Confirmed reservations save here and sync with your Lakbay+ account.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: LakbayColors.textSecondary,
                            fontSize: 14.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
                  itemCount: widget.repo.bookings.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final res = widget.repo.bookings[index];
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: LakbayColors.cardBorder),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: LakbayColors.primaryLight,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.confirmation_number_outlined,
                              color: LakbayColors.primaryDark,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  res.summaryTitle,
                                  style: const TextStyle(
                                    fontFamily: 'FigGrotesk',
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  res.itemsSummary,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: LakbayColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${res.syncedToCloud ? 'Cloud synced' : 'Saved locally'} • ${res.paymentMethod.toUpperCase()}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: res.syncedToCloud
                                        ? LakbayColors.successGreen
                                        : LakbayColors.tealAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.repo.formatPrice(res.totalUsd),
                            style: const TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: LakbayColors.tealDeep,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ))
          : items.isEmpty
              ? Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 110),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        color: LakbayColors.primaryLight,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'L✦',
                        style: TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: LakbayColors.primaryDark,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _showPast ? 'No past bookings' : 'No bookings yet',
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w800,
                        fontSize: 21,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ask Lakbay+ for a hotel or a flight and it lands here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: LakbayColors.textSecondary,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    ElevatedButton.icon(
                      onPressed: () => widget.repo.setActiveNavIndex(2),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LakbayColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Ask Lakbay+'),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: LakbayColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset(
                          item.imageAsset,
                          width: 68,
                          height: 68,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 68,
                            height: 68,
                            color: LakbayColors.tealAccent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: LakbayColors.primaryLight,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                item.category.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: LakbayColors.primaryDark,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.title,
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 15.5,
                              ),
                            ),
                            Text(
                              item.subtitle,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            widget.repo.formatPrice(item.priceUsd),
                            style: const TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: LakbayColors.tealDeep,
                            ),
                          ),
                          IconButton(
                            onPressed: () =>
                                widget.repo.removeFromBasket(item.id),
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 20, color: LakbayColors.textMuted),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
      bottomNavigationBar: items.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${items.length} Travel Items',
                          style: const TextStyle(
                            fontSize: 12,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                        Text(
                          widget.repo.formatPrice(widget.repo.basketTotalUsd),
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 22,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: _openExpressCheckoutSheet,
                      icon: const Icon(Icons.flash_on_rounded, size: 18),
                      label: const Text('Express Checkout'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _SegmentPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? LakbayColors.primaryLight : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? LakbayColors.primaryDark : LakbayColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
