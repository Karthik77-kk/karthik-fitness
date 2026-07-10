import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../services/haptics.dart';
import '../widgets/input_formatters.dart';
import '../providers/fitness_provider.dart';
import '../models/models.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/date_picker_chip.dart';
import '../widgets/kit/kit.dart';

class SmartScaleScreen extends StatefulWidget {
  final bool embedded;
  const SmartScaleScreen({super.key, this.embedded = false});
  @override
  State<SmartScaleScreen> createState() => _SmartScaleScreenState();
}

class _SmartScaleScreenState extends State<SmartScaleScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController _tab;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Always use _tab explicitly — prevents the TabBar from accidentally binding
    // to an outer DefaultTabController (e.g. BodyScreen's Stats|Scale controller)
    // when embedded inside another DefaultTabController scope.
    final tabBar = TabBar(
      controller: _tab,
      tabs: const [Tab(text: 'Log Today'), Tab(text: 'History')],
      indicatorColor: const Color(0xFF30D158),
      labelColor: const Color(0xFF30D158),
      unselectedLabelColor: const Color(0xFF8E8E93),
    );
    final tabView = TabBarView(
      controller: _tab,
      children: const [_LogTab(), _HistoryTab()],
    );

    if (widget.embedded) {
      return Column(children: [
        tabBar,
        Expanded(child: tabView),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Scale'),
        bottom: tabBar,
      ),
      body: tabView,
    );
  }
}

class _LogTab extends StatefulWidget {
  const _LogTab();
  @override
  State<_LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<_LogTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _formKey = GlobalKey<FormState>();

  DateTime _logDate = DateTime.now(); // backdate target for the scale reading
  final _weight = TextEditingController();
  final _bodyFatPct = TextEditingController();
  final _bodyFatKg = TextEditingController();
  final _muscleMassKg = TextEditingController();
  final _muscleMassPct = TextEditingController();
  final _leanBodyMass = TextEditingController();
  final _bioAge = TextEditingController();
  final _visceralFat = TextEditingController();
  final _bmr = TextEditingController();
  final _bodyWater = TextEditingController();
  final _boneMass = TextEditingController();
  final _proteinPct = TextEditingController();
  final _skeletalMuscle = TextEditingController();

  bool _didAutoPrefill = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefill());
  }

  void _prefill() {
    if (!mounted) return;
    // Only prefill if ALL fields are empty (don't overwrite user edits)
    if (_weight.text.isNotEmpty) return;
    final latest = context.read<FitnessProvider>().latestScaleEntry;
    if (latest == null) return;
    setState(() {
      _weight.text = latest.weightKg.toStringAsFixed(1);
      _bodyFatPct.text = latest.bodyFatPercent.toStringAsFixed(1);
      _bodyFatKg.text = latest.bodyFatKg.toStringAsFixed(1);
      _muscleMassKg.text = latest.muscleMassKg.toStringAsFixed(1);
      _muscleMassPct.text = latest.muscleMassPercent.toStringAsFixed(1);
      _leanBodyMass.text = latest.leanBodyMassKg.toStringAsFixed(1);
      _bioAge.text = latest.biologicalAge.toString();
      _visceralFat.text = latest.visceralFatIndex.toString();
      _bmr.text = latest.bmr.toStringAsFixed(0);
      _bodyWater.text = latest.bodyWaterPercent.toStringAsFixed(1);
      _boneMass.text = latest.boneMassKg.toStringAsFixed(2);
      _proteinPct.text = latest.proteinPercent.toStringAsFixed(1);
      _skeletalMuscle.text = latest.skeletalMuscleMassKg.toStringAsFixed(1);
    });
  }

  @override
  void dispose() {
    for (final c in [
      _weight,
      _bodyFatPct,
      _bodyFatKg,
      _muscleMassKg,
      _muscleMassPct,
      _leanBodyMass,
      _bioAge,
      _visceralFat,
      _bmr,
      _bodyWater,
      _boneMass,
      _proteinPct,
      _skeletalMuscle
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_formKey.currentState == null || !_formKey.currentState!.validate())
      return;
    final weightVal = double.tryParse(_weight.text);
    if (weightVal == null)
      return; // form validator should catch this, but guard anyway
    final entry = SmartScaleEntry(
      id: const Uuid().v4(),
      date: _logDate,
      weightKg: weightVal,
      bodyFatPercent: double.tryParse(_bodyFatPct.text) ?? 0,
      bodyFatKg: double.tryParse(_bodyFatKg.text) ?? 0,
      muscleMassKg: double.tryParse(_muscleMassKg.text) ?? 0,
      muscleMassPercent: double.tryParse(_muscleMassPct.text) ?? 0,
      leanBodyMassKg: double.tryParse(_leanBodyMass.text) ?? 0,
      biologicalAge: int.tryParse(_bioAge.text) ?? 0,
      visceralFatIndex: int.tryParse(_visceralFat.text) ?? 0,
      bmr: double.tryParse(_bmr.text) ?? 0,
      bodyWaterPercent: double.tryParse(_bodyWater.text) ?? 0,
      boneMassKg: double.tryParse(_boneMass.text) ?? 0,
      proteinPercent: double.tryParse(_proteinPct.text) ?? 0,
      skeletalMuscleMassKg: double.tryParse(_skeletalMuscle.text) ?? 0,
    );
    await context.read<FitnessProvider>().logScaleEntry(entry);
    Haptics.heavy();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scale data saved! BMI and calorie targets updated.'),
          backgroundColor: Color(0xFF30D158),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required for AutomaticKeepAliveClientMixin
    final latest = context.watch<FitnessProvider>().latestScaleEntry;
    final subtitle = latest != null
        ? 'Pre-filled from ${latest.date.day}/${latest.date.month}/${latest.date.year} — update changed values'
        : 'Enter today\'s scale readings';

    // Handle data arriving after screen was open (e.g. after import on fresh install).
    // When latestScaleEntry goes from null → non-null while the screen is alive,
    // build() re-runs but initState doesn't — schedule a prefill for next frame.
    if (latest != null && !_didAutoPrefill && _weight.text.isEmpty) {
      _didAutoPrefill =
          true; // one-shot: don't re-fill after the user clears a field
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _weight.text.isEmpty) _prefill();
      });
    }
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    subtitle,
                    style:
                        const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                // Backdate: which day this reading is logged to.
                DatePickerChip(
                  date: _logDate,
                  onChanged: (d) => setState(() => _logDate = d),
                  maxPastDays: 365,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section('Essential', [
              _Field('Weight (kg)', _weight, required: true, min: 10, max: 500),
              _Field('Body Fat (%)', _bodyFatPct, min: 2, max: 60),
              _Field('Body Fat (kg)', _bodyFatKg, min: 0.5, max: 200),
              _Field('BMR (kcal)', _bmr, isDecimal: false, min: 500, max: 5000),
            ]),
            _Section('Muscle & Lean Mass', [
              _Field('Muscle Mass (kg)', _muscleMassKg, min: 5, max: 200),
              _Field('Muscle Mass (%)', _muscleMassPct, min: 10, max: 70),
              _Field('Lean Body Mass (kg)', _leanBodyMass, min: 5, max: 200),
              _Field('Skeletal Muscle (kg)', _skeletalMuscle, min: 5, max: 150),
            ]),
            _Section('Other Metrics', [
              _Field('Body Water (%)', _bodyWater, min: 30, max: 80),
              _Field('Bone Mass (kg)', _boneMass, min: 0.5, max: 10),
              _Field('Protein (%)', _proteinPct, min: 5, max: 30),
              _Field('Visceral Fat Index', _visceralFat,
                  isDecimal: false, min: 1, max: 59),
              _Field('Biological Age (yrs)', _bioAge,
                  isDecimal: false, min: 10, max: 120),
            ]),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF30D158),
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Save Scale Data',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _Section(String title, List<Widget> fields) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Green accent bar + white uppercase title — clearly separates sections
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 12),
          child: Row(children: [
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFF30D158),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(title.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
          ]),
        ),
        // Card the field group so it matches the carded Body › Stats form
        // and inherits the shared glass-look surface.
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: fields,
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _Field(String label, TextEditingController ctrl,
      {bool required = false,
      bool isDecimal = true,
      double? min,
      double? max}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        Expanded(
          flex: 1,
          child: RichText(
            text: TextSpan(
              text: label,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
              children: required
                  ? [
                      const TextSpan(
                          text: ' *',
                          style: TextStyle(color: Color(0xFFFF453A)))
                    ]
                  : [],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 1,
          child: TextFormField(
            controller: ctrl,
            keyboardType: isDecimal
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.number,
            inputFormatters: isDecimal ? positiveDecimalInput : positiveIntInput,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            textAlign: TextAlign.right,
            decoration: InputDecoration(
              hintText: '—',
              hintStyle:
                  const TextStyle(color: Color(0xFF48484A), fontSize: 15),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              errorStyle: const TextStyle(fontSize: 10, height: 0.8),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return required ? 'Required' : null;
              }
              final parsed = double.tryParse(v.trim());
              if (parsed == null) return 'Invalid';
              if (min != null && parsed < min) return '< $min';
              if (max != null && parsed > max) return '> $max';
              return null;
            },
          ),
        ),
      ]),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();
  @override
  Widget build(BuildContext context) {
    final history =
        context.watch<FitnessProvider>().scaleHistory.reversed.toList();
    if (history.isEmpty) {
      return const AppEmptyState(
        icon: '⚖️',
        title: 'No scale data yet',
        subtitle: 'Log your first reading in the Log Today tab',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      itemCount: history.length,
      itemBuilder: (ctx, i) {
        final e = history[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E22),
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadows.card,
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(
                '${e.date.day}/${e.date.month}/${e.date.year}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text('${e.weightKg.toStringAsFixed(1)} kg',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF30D158))),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _Pill('Fat ${e.bodyFatPercent.toStringAsFixed(1)}%',
                  const Color(0xFFFF9F0A)),
              _Pill('Muscle ${e.muscleMassKg.toStringAsFixed(1)}kg',
                  const Color(0xFF30D158)),
              _Pill('Water ${e.bodyWaterPercent.toStringAsFixed(1)}%',
                  const Color(0xFF40C8E0)),
              _Pill('BMR ${e.bmr.toStringAsFixed(0)} kcal',
                  const Color(0xFFFF9F0A)),
              _Pill('Bio Age ${e.biologicalAge}', Colors.white54),
              _Pill('Visceral ${e.visceralFatIndex}', Colors.white54),
            ]),
          ]),
        );
      },
    );
  }

  Widget _Pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
