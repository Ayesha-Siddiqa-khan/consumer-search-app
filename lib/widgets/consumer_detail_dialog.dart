import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/consumer_model.dart';
import '../theme/app_theme.dart';
import 'bill_history_dialog.dart';

class ConsumerDetailDialog extends StatelessWidget {
  final Consumer consumer;

  const ConsumerDetailDialog({super.key, required this.consumer});

  static void show(BuildContext context, Consumer consumer) {
    showDialog(
      context: context,
      builder: (ctx) => ConsumerDetailDialog(consumer: consumer),
    );
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard: $text'),
        duration: const Duration(seconds: 2),
        backgroundColor: AppTheme.primaryGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SelectionArea(
        child: Container(
          width: 650,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: const BoxDecoration(
                color: AppTheme.primaryGreen,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_pin_rounded, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          consumer.consumerName.isNotEmpty ? consumer.consumerName : 'Consumer Dossier',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Sr #${consumer.srNo} • Order/Reg #${consumer.orderNo.isNotEmpty ? consumer.orderNo : "N/A"}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  _buildStatusChip(consumer.consumerStatus, isConsumerStatus: true),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Quick Key Info Cards
                    Row(
                      children: [
                        Expanded(
                          child: _buildInfoCard(
                            context,
                            title: 'Connection No.',
                            value: consumer.connectionNo,
                            icon: Icons.tag,
                            canCopy: true,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildInfoCard(
                            context,
                            title: 'Old Connection No.',
                            value: consumer.oldConnectionNo,
                            icon: Icons.history,
                            canCopy: true,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildInfoCard(
                            context,
                            title: 'Mobile',
                            value: consumer.mobile,
                            icon: Icons.phone_android,
                            canCopy: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Full Detailed Grid
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Consumer & Location Details',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.darkGreen,
                            ),
                          ),
                          const Divider(height: 20),
                          _buildDetailRow('Father / Husband Name', consumer.fatherHusbandName),
                          _buildDetailRow('Sector', consumer.sector),
                          _buildDetailRow('Locality', consumer.locality),
                          _buildDetailRow('Address', consumer.address),
                          _buildDetailRow('Rate Type', consumer.rateType),
                          _buildDetailRow(
                            'Connection Date (DD-MM-YYYY)',
                            consumer.connectionDate,
                            highlight: true,
                          ),
                          _buildDetailRow(
                            'Connection Status',
                            consumer.connectionStatus,
                            badge: _buildStatusChip(consumer.connectionStatus),
                          ),
                          _buildDetailRow(
                            'Consumer Status',
                            consumer.consumerStatus,
                            badge: _buildStatusChip(consumer.consumerStatus, isConsumerStatus: true),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFFF9FAFB),
                border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Local Government & Community Development Dept.',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.history, size: 16),
                        label: const Text('View Bill History'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF26522),
                          side: const BorderSide(color: Color(0xFFF26522)),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          BillHistoryDialog.show(
                            context: context,
                            connectionNo: consumer.connectionNo,
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Close'),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildInfoCard(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
    bool canCopy = false,
  }) {
    final displayVal = value.trim().isNotEmpty ? value.trim() : 'N/A';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppTheme.primaryGreen),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canCopy && displayVal != 'N/A')
                InkWell(
                  onTap: () => _copyToClipboard(context, displayVal, title),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.copy, size: 14, color: AppTheme.primaryGreen),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            displayVal,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool highlight = false, Widget? badge}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            child: badge ??
                Text(
                  value.trim().isNotEmpty ? value.trim() : 'N/A',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                    color: highlight ? AppTheme.primaryGreen : Colors.black87,
                  ),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String status, {bool isConsumerStatus = false}) {
    final clean = status.trim().toLowerCase();
    Color bg = Colors.grey.shade200;
    Color fg = Colors.grey.shade800;

    if (isConsumerStatus) {
      if (clean == 'active') {
        bg = AppTheme.statusActiveBg;
        fg = AppTheme.statusActiveText;
      } else {
        bg = AppTheme.statusInactiveBg;
        fg = AppTheme.statusInactiveText;
      }
    } else {
      if (clean.contains('regular')) {
        bg = AppTheme.statusActiveBg;
        fg = AppTheme.statusActiveText;
      } else if (clean.contains('closed') || clean.contains('dead')) {
        bg = AppTheme.statusInactiveBg;
        fg = AppTheme.statusInactiveText;
      } else if (clean.contains('suspend')) {
        bg = AppTheme.statusSuspendedBg;
        fg = AppTheme.statusSuspendedText;
      } else if (clean.contains('demand')) {
        bg = AppTheme.statusNewDemandBg;
        fg = AppTheme.statusNewDemandText;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status.isNotEmpty ? status : 'N/A',
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
