import 'package:flutter/material.dart';

import '../services/access_notices.dart';

import '../design/lakbay_tokens.dart';
import '../design/lakbay_type.dart';
/// Full permit / access notice for the trip detail screen.
class AccessNoticeCard extends StatelessWidget {
  const AccessNoticeCard({super.key, required this.notice});

  final AccessNotice notice;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${notice.title}. ${notice.body}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: LkColors.mangoSoft,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: LkColors.mango),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.badge_outlined,
                color: Colors.deepOrange,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: TextStyle(
                        fontFamily: LkType.displayFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: LkColors.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notice.body,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: LkColors.text,
                      ),
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
}

/// One-line notice for tight spaces such as the map day card.
class AccessNoticePill extends StatelessWidget {
  const AccessNoticePill({super.key, required this.notice});

  final AccessNotice notice;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: notice.body,
      child: Row(
        children: [
          const Icon(Icons.badge_outlined, size: 15, color: Colors.deepOrange),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              notice.shortLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: LkColors.mangoText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
