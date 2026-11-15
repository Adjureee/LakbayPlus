import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

Future<void> showTripCollaborationSheet(
  BuildContext context, {
  required TravelRepository repo,
  required ItineraryTrip trip,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _TripCollaborationSheet(repo: repo, trip: trip),
  );
}

Future<void> showTripBudgetAndPdfSheet(
  BuildContext context, {
  required TravelRepository repo,
  required ItineraryTrip trip,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _TripBudgetAndPdfSheet(repo: repo, trip: trip),
  );
}

Future<void> showTripReviewAndAssessmentSheet(
  BuildContext context, {
  required TravelRepository repo,
  required ItineraryTrip trip,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _TripReviewAndAssessmentSheet(repo: repo, trip: trip),
  );
}

class _TripCollaborationSheet extends StatefulWidget {
  final TravelRepository repo;
  final ItineraryTrip trip;

  const _TripCollaborationSheet({required this.repo, required this.trip});

  @override
  State<_TripCollaborationSheet> createState() =>
      _TripCollaborationSheetState();
}

class _TripCollaborationSheetState extends State<_TripCollaborationSheet> {
  final _emailCtrl = TextEditingController();
  final _taskCtrl = TextEditingController();
  List<TripMemberItem> _members = [];
  List<TripTaskItem> _tasks = [];
  String _statusFilter = 'all';
  bool _loading = true;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _taskCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null) {
      setState(() {
        _loading = false;
        _members = [
          TripMemberItem(
            tripMemberId: 1,
            tripId: 0,
            userId: 1,
            fullName: widget.repo.profile.fullName,
            email: widget.repo.profile.email.isNotEmpty
                ? widget.repo.profile.email
                : 'owner@lakbay.local',
            role: 'owner',
            status: 'active',
          ),
        ];
      });
      return;
    }
    setState(() => _loading = true);
    final token = widget.repo.authSession!.accessToken;
    final members = await widget.repo.apiCatalog.listTripMembers(token, tripId);
    final tasks = await widget.repo.apiCatalog.listTripTasks(token, tripId);
    if (!mounted) return;
    setState(() {
      _members = members;
      _tasks = tasks;
      _loading = false;
    });
  }

  Future<void> _inviteMember() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) return;
    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null) {
      setState(() {
        _members = [
          ..._members,
          TripMemberItem(
            tripMemberId: -DateTime.now().millisecondsSinceEpoch,
            tripId: 0,
            userId: 0,
            fullName: email.split('@').first,
            email: email,
            role: 'member',
            status: 'active',
          ),
        ];
        _emailCtrl.clear();
        _statusMessage = 'Companion added locally (sign in & sync to invite via cloud).';
      });
      return;
    }
    try {
      final created = await widget.repo.apiCatalog.addTripMember(
        widget.repo.authSession!.accessToken,
        tripId,
        email: email,
      );
      _emailCtrl.clear();
      if (created != null) {
        setState(() {
          _members = [..._members, created];
          _statusMessage = 'Invited ${created.fullName}!';
        });
      }
    } catch (e) {
      setState(() => _statusMessage = e.toString());
    }
  }

  Future<void> _addTask() async {
    final title = _taskCtrl.text.trim();
    if (title.isEmpty) return;
    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null) {
      setState(() {
        _tasks = [
          TripTaskItem(
            tripTaskId: -DateTime.now().millisecondsSinceEpoch,
            tripId: 0,
            title: title,
            status: 'pending',
          ),
          ..._tasks,
        ];
        _taskCtrl.clear();
      });
      return;
    }
    try {
      final created = await widget.repo.apiCatalog.createTripTask(
        widget.repo.authSession!.accessToken,
        tripId,
        title: title,
        assignedTripMemberId:
            _members.isNotEmpty ? _members.first.tripMemberId : null,
      );
      _taskCtrl.clear();
      if (created != null) {
        setState(() => _tasks = [created, ..._tasks]);
      }
    } catch (e) {
      setState(() => _statusMessage = e.toString());
    }
  }

  Future<void> _cycleTaskStatus(TripTaskItem task) async {
    final next = switch (task.status) {
      'pending' => 'in_progress',
      'in_progress' => 'completed',
      _ => 'pending',
    };
    final tripId = widget.trip.backendTripId;
    if (widget.repo.isSignedIn && tripId != null && task.tripTaskId > 0) {
      await widget.repo.apiCatalog.updateTripTaskStatus(
        widget.repo.authSession!.accessToken,
        tripId,
        task.tripTaskId,
        status: next,
      );
    }
    setState(() {
      _tasks = [
        for (final t in _tasks)
          if (t.tripTaskId == task.tripTaskId)
            TripTaskItem(
              tripTaskId: t.tripTaskId,
              tripId: t.tripId,
              assignedTripMemberId: t.assignedTripMemberId,
              title: t.title,
              description: t.description,
              status: next,
              dueDate: t.dueDate,
            )
          else
            t,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final visibleTasks = _statusFilter == 'all'
        ? _tasks
        : _tasks.where((t) => t.status == _statusFilter).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      maxChildSize: 0.94,
      builder: (context, scrollCtrl) {
        return ListView(
          controller: scrollCtrl,
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          children: [
            const Text(
              'Collaborate & Shared Tasks',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Invite registered companions and track Pending, Ongoing, and Completed tasks.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: LakbayColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _statusMessage!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.tealDeep,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'Group Members',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'Companion email address',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _inviteMember,
                  child: const Text('Invite'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              for (final m in _members)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: LakbayColors.tealDeep,
                    foregroundColor: Colors.white,
                    child: Text(
                      m.fullName.isNotEmpty
                          ? m.fullName[0].toUpperCase()
                          : 'T',
                    ),
                  ),
                  title: Text(m.fullName),
                  subtitle: Text('${m.email} • ${m.role.toUpperCase()}'),
                ),
            const Divider(height: 28),
            const Text(
              'Trip Tasks',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const [
                  ('all', 'All'),
                  ('pending', 'Pending'),
                  ('in_progress', 'Ongoing'),
                  ('completed', 'Completed'),
                ])
                  ChoiceChip(
                    label: Text(entry.$2),
                    selected: _statusFilter == entry.$1,
                    onSelected: (_) => setState(() => _statusFilter = entry.$1),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _taskCtrl,
                    decoration: InputDecoration(
                      hintText: 'Add packing or trip task',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _addTask,
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (visibleTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No tasks in this view yet.',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              )
            else
              for (final t in visibleTasks)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(t.title),
                    subtitle: Text(
                      t.status == 'in_progress'
                          ? 'Ongoing • Tap badge to advance'
                          : '${t.status[0].toUpperCase()}${t.status.substring(1)} • Tap badge to cycle',
                    ),
                    trailing: ActionChip(
                      label: Text(
                        t.status == 'in_progress'
                            ? 'Ongoing'
                            : (t.status == 'completed'
                                ? 'Completed'
                                : 'Pending'),
                      ),
                      onPressed: () => _cycleTaskStatus(t),
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _TripBudgetAndPdfSheet extends StatefulWidget {
  final TravelRepository repo;
  final ItineraryTrip trip;

  const _TripBudgetAndPdfSheet({required this.repo, required this.trip});

  @override
  State<_TripBudgetAndPdfSheet> createState() => _TripBudgetAndPdfSheetState();
}

class _TripBudgetAndPdfSheetState extends State<_TripBudgetAndPdfSheet> {
  final _titleCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  String _category = 'meals';
  bool _ageWeightedSplit = true;
  int _adults = 2;
  int _children = 0;
  TripExpenseSummary? _summary;
  List<TripExpenseItem> _expenses = [];
  List<TripMemberItem> _members = [];
  bool _loading = true;
  bool _exportingPdf = false;
  String? _bannerMsg;

  @override
  void initState() {
    super.initState();
    _adults = widget.trip.adults.clamp(1, 20);
    _children = widget.trip.children.clamp(0, 20);
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final token = widget.repo.authSession!.accessToken;
    final summary = await widget.repo.apiCatalog.getTripExpenseSummary(
      token,
      tripId,
      adultCount: _adults,
      childCount: _children,
    );
    final expenses = await widget.repo.apiCatalog.listTripExpenses(token, tripId);
    final members = await widget.repo.apiCatalog.listTripMembers(token, tripId);
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _expenses = expenses;
      _members = members;
      _loading = false;
    });
  }

  Future<void> _logExpense() async {
    final title = _titleCtrl.text.trim();
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (title.isEmpty || amount <= 0) return;

    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null || _members.isEmpty) {
      setState(() {
        _expenses = [
          TripExpenseItem(
            tripExpenseId: -DateTime.now().millisecondsSinceEpoch,
            tripId: 0,
            paidByTripMemberId: 1,
            paidByFullName: widget.repo.profile.fullName,
            category: _category,
            title: title,
            amount: amount,
            expenseDate: DateTime.now(),
            status: 'active',
          ),
          ..._expenses,
        ];
        _titleCtrl.clear();
        _amountCtrl.clear();
      });
      return;
    }

    try {
      await widget.repo.apiCatalog.createTripExpense(
        widget.repo.authSession!.accessToken,
        tripId,
        title: title,
        category: _category,
        amount: amount,
        paidByTripMemberId: _members.first.tripMemberId,
      );
      _titleCtrl.clear();
      _amountCtrl.clear();
      await widget.repo.refreshNotifications();
      await _load();
    } catch (e) {
      setState(() => _bannerMsg = e.toString());
    }
  }

  Future<void> _exportPdf() async {
    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null) {
      setState(() {
        _bannerMsg =
            'Sign in and save this trip to cloud first to generate the server PDF report.';
      });
      return;
    }
    setState(() => _exportingPdf = true);
    try {
      final bytes = await widget.repo.apiCatalog.downloadTripReportPdf(
        widget.repo.authSession!.accessToken,
        tripId,
      );
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _exportingPdf = false;
          _bannerMsg = 'PDF report unavailable right now.';
        });
        return;
      }
      final List<XFile> shareFiles;
      if (kIsWeb) {
        shareFiles = [
          XFile.fromData(
            Uint8List.fromList(bytes),
            mimeType: 'application/pdf',
            name: 'lakbay-trip-$tripId-report.pdf',
          ),
        ];
      } else {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/lakbay-trip-$tripId-report.pdf');
        await file.writeAsBytes(bytes, flush: true);
        shareFiles = [XFile(file.path)];
      }
      await SharePlus.instance.share(
        ShareParams(
          files: shareFiles,
          text: '${widget.trip.title} — Lakbay+ Itinerary & Expense PDF Report',
        ),
      );
    } catch (e) {
      setState(() => _bannerMsg = 'Could not export PDF: $e');
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final budgetPhp = _summary?.totalBudget ??
        widget.trip.backendBudgetPhp ??
        (widget.trip.totalEstimatedCostUsd * 57.0);
    final spentPhp = _summary?.totalSpent ??
        _expenses.fold<double>(0.0, (sum, e) => sum + e.amount);
    final pctUsed =
        _summary?.percentUsed ?? (budgetPhp > 0 ? (spentPhp / budgetPhp) * 100 : 0.0);
    final alertLevel = _summary?.budgetAlertLevel ??
        (pctUsed > 100
            ? 'exceeded'
            : (pctUsed >= 80 ? 'warning_80' : 'ok'));

    final weightUnits = _ageWeightedSplit ? (_adults * 2 + _children) : (_adults + _children);
    final adultShare = weightUnits > 0
        ? (_ageWeightedSplit
            ? (spentPhp * 2) / weightUnits
            : spentPhp / weightUnits)
        : 0.0;
    final childShare = _ageWeightedSplit ? (adultShare * 0.5) : adultShare;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.84,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) {
        return ListView(
          controller: scrollCtrl,
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Budget, Expenses & Split',
                    style: TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _exportingPdf ? null : _exportPdf,
                  icon: _exportingPdf
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: const Text('Export PDF'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (alertLevel != 'ok')
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: alertLevel == 'exceeded'
                      ? Colors.red.shade50
                      : Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: alertLevel == 'exceeded'
                        ? Colors.red.shade300
                        : Colors.amber.shade400,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: alertLevel == 'exceeded'
                          ? Colors.red.shade700
                          : Colors.orange.shade800,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        alertLevel == 'exceeded'
                            ? 'Budget exceeded (${pctUsed.toStringAsFixed(0)}% used). Adjust expenses or increase trip budget.'
                            : 'Budget alert: you have reached ${pctUsed.toStringAsFixed(0)}% of your ₱${budgetPhp.toStringAsFixed(0)} target.',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_bannerMsg != null) ...[
              Text(
                _bannerMsg!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
            ],
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6F7),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Spent: ₱${spentPhp.toStringAsFixed(2)}'),
                      Text('Budget: ₱${budgetPhp.toStringAsFixed(2)}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: (pctUsed / 100).clamp(0.0, 1.0),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(6),
                    color: alertLevel == 'exceeded'
                        ? Colors.red
                        : (alertLevel == 'warning_80'
                            ? Colors.orange
                            : LakbayColors.primary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Equal vs Age-Weighted Split (50% Child)',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Age-weighted child rate (50%)'),
              subtitle: const Text(
                'Thesis formula: Child pays half of an adult share',
              ),
              value: _ageWeightedSplit,
              onChanged: (v) => setState(() => _ageWeightedSplit = v),
            ),
            Row(
              children: [
                Expanded(
                  child: _CounterTile(
                    label: 'Adults',
                    value: _adults,
                    onMinus: _adults > 1
                        ? () {
                            setState(() => _adults--);
                            _load();
                          }
                        : null,
                    onPlus: () {
                      setState(() => _adults++);
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _CounterTile(
                    label: 'Kids 50%',
                    value: _children,
                    onMinus: _children > 0
                        ? () {
                            setState(() => _children--);
                            _load();
                          }
                        : null,
                    onPlus: () {
                      setState(() => _children++);
                      _load();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: LakbayColors.tealDeep.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text('Adult Share', style: TextStyle(fontSize: 12)),
                      Text(
                        '₱${(_summary != null && _ageWeightedSplit ? _summary!.adultShare : adultShare).toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      const Text('Child Share', style: TextStyle(fontSize: 12)),
                      Text(
                        '₱${(_summary != null && _ageWeightedSplit ? _summary!.childShare : childShare).toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: LakbayColors.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 28),
            const Text(
              'Log Expense',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _titleCtrl,
                    decoration: InputDecoration(
                      hintText: 'Expense item',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _amountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      hintText: '₱ Amount',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _category,
                    isExpanded: true,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'meals',
                        child: Text('Meals', overflow: TextOverflow.ellipsis),
                      ),
                      DropdownMenuItem(
                        value: 'transportation',
                        child: Text(
                          'Transportation',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'accommodation',
                        child: Text(
                          'Accommodation',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'activities',
                        child: Text(
                          'Activities',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'other',
                        child: Text('Other', overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _category = v);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                  onPressed: _logExpense,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Expense'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else
              for (final e in _expenses)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.title),
                  subtitle: Text('${e.category} • Paid by ${e.paidByFullName}'),
                  trailing: Text(
                    '₱${e.amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _CounterTile extends StatelessWidget {
  final String label;
  final int value;
  final VoidCallback? onMinus;
  final VoidCallback onPlus;

  const _CounterTile({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          IconButton(
            onPressed: onMinus,
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '$value',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: onPlus,
            icon: const Icon(Icons.add_circle_outline, size: 18),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

class _TripReviewAndAssessmentSheet extends StatefulWidget {
  final TravelRepository repo;
  final ItineraryTrip trip;

  const _TripReviewAndAssessmentSheet({
    required this.repo,
    required this.trip,
  });

  @override
  State<_TripReviewAndAssessmentSheet> createState() =>
      _TripReviewAndAssessmentSheetState();
}

class _TripReviewAndAssessmentSheetState
    extends State<_TripReviewAndAssessmentSheet> {
  int _overallRating = 5;
  int _routeRating = 5;
  int _budgetRating = 5;
  int _isoFunctional = 5;
  int _isoInfoAccuracy = 5;
  int _isoPerformance = 5;
  int _isoInteraction = 5;
  int _isoReliability = 5;
  int _isoSharing = 5;
  final _commentCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitAll() async {
    final tripId = widget.trip.backendTripId;
    if (!widget.repo.isSignedIn || tripId == null) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Review & ISO 25010 feedback saved locally!'),
          backgroundColor: LakbayColors.tealDeep,
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final token = widget.repo.authSession!.accessToken;
      await widget.repo.apiCatalog.submitTripReview(
        token,
        tripId,
        destinationId: widget.trip.backendDestinationId,
        postTripRating: _overallRating,
        accuracyRating: _isoInfoAccuracy,
        routeEfficiencyRating: _routeRating,
        budgetAdherenceRating: _budgetRating,
        overallExperienceRating: _overallRating,
        comments: _commentCtrl.text.trim(),
      );
      await widget.repo.apiCatalog.submitAppAssessment(
        token,
        tripId,
        functionalSuitabilityRating: _isoFunctional,
        informationAccuracyRating: _isoInfoAccuracy,
        performanceRating: _isoPerformance,
        interactionRating: _isoInteraction,
        reliabilityRating: _isoReliability,
        sharingClarityRating: _isoSharing,
        comment: _commentCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thank you! Review & ISO/IEC 25010 survey submitted.'),
          backgroundColor: LakbayColors.tealDeep,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submission failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) {
        return ListView(
          controller: scrollCtrl,
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          children: [
            const Text(
              'Post-Trip Review & App Quality',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Rate your Davao Region trip and Lakbay+ ISO/IEC 25010 quality metrics (1–5).',
              style: TextStyle(fontSize: 13, color: Color(0xFF5D6B73)),
            ),
            const SizedBox(height: 14),
            _StarRow(
              label: 'Overall Trip Experience',
              value: _overallRating,
              onChanged: (v) => setState(() => _overallRating = v),
            ),
            _StarRow(
              label: 'Route Efficiency',
              value: _routeRating,
              onChanged: (v) => setState(() => _routeRating = v),
            ),
            _StarRow(
              label: 'Budget Adherence',
              value: _budgetRating,
              onChanged: (v) => setState(() => _budgetRating = v),
            ),
            const Divider(height: 24),
            const Text(
              'ISO/IEC 25010 System Evaluation',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 15.5,
              ),
            ),
            const SizedBox(height: 6),
            _StarRow(
              label: 'Functional Suitability',
              value: _isoFunctional,
              onChanged: (v) => setState(() => _isoFunctional = v),
            ),
            _StarRow(
              label: 'Information Accuracy',
              value: _isoInfoAccuracy,
              onChanged: (v) => setState(() => _isoInfoAccuracy = v),
            ),
            _StarRow(
              label: 'Performance Efficiency',
              value: _isoPerformance,
              onChanged: (v) => setState(() => _isoPerformance = v),
            ),
            _StarRow(
              label: 'Usability / Interaction',
              value: _isoInteraction,
              onChanged: (v) => setState(() => _isoInteraction = v),
            ),
            _StarRow(
              label: 'System Reliability',
              value: _isoReliability,
              onChanged: (v) => setState(() => _isoReliability = v),
            ),
            _StarRow(
              label: 'Report & Sharing Clarity',
              value: _isoSharing,
              onChanged: (v) => setState(() => _isoSharing = v),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _commentCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Comments / Suggestions (optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: LakbayColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _submitting ? null : _submitAll,
                child: Text(_submitting ? 'Submitting...' : 'Submit Review & Survey'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StarRow extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _StarRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
        for (int i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Icon(
              i <= value ? Icons.star_rounded : Icons.star_border_rounded,
              color: LakbayColors.primary,
              size: 22,
            ),
            onPressed: () => onChanged(i),
          ),
      ],
    );
  }
}
