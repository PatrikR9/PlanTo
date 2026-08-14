import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/design_system/components/components.dart';
import '../../../../core/error/error_text.dart';
import '../../../../core/error/failure.dart';
import '../../data/stop_search_repository.dart';
import '../../domain/transit_stop.dart';

/// Jak dlouho se čeká, než se z psaní stane dotaz.
///
/// Není to animace, takže to nepatří mezi Motion tokeny. 350 ms je pod
/// hranicí, kdy to člověk vnímá jako prodlevu, a zároveň nad rychlostí,
/// jakou se píše uvnitř slova — „praha hl" tak vyrobí jeden dotaz, ne osm.
const Duration _kDebounce = Duration(milliseconds: 350);

/// Pod dva znaky se nehledá. Jedno písmeno vrátí půl databáze a uživatel
/// z toho nic nevyčte; server to zahazuje taky, tohle jen ušetří cestu tam.
const int _kMinQuery = 2;

/// Vybere zastávku, nádraží nebo stanici.
///
/// Jeden komponent pro odjezd i cíl — obojí je stejná otázka a dvě
/// implementace by se rozešly. [near] je volitelná kotva pro řazení: když
/// ji předáme, bližší zastávky jdou nahoru.
///
/// Geolokace tu schválně není. Aplikace zatím žádnou nemá a přidávat kvůli
/// řazení oprávnění k poloze je nepoměr — u cíle je stejně dobrá kotva
/// výchozí bod výletu, který už známe.
Future<TransitStop?> pickTransitStop(
  BuildContext context, {
  required String title,
  String? hint,
  ({double lat, double lon})? near,
}) {
  return showModalBottomSheet<TransitStop>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _StopPickerSheet(title: title, hint: hint, near: near),
  );
}

class _StopPickerSheet extends ConsumerStatefulWidget {
  const _StopPickerSheet({required this.title, this.hint, this.near});

  final String title;
  final String? hint;
  final ({double lat, double lon})? near;

  @override
  ConsumerState<_StopPickerSheet> createState() => _StopPickerSheetState();
}

class _StopPickerSheetState extends ConsumerState<_StopPickerSheet> {
  final TextEditingController _controller = TextEditingController();

  Timer? _debounce;

  /// Pořadové číslo dotazu. Odpovědi chodí mimo pořadí — pomalejší „pra"
  /// může dorazit po rychlejším „praha" a přepsat správný výsledek horším.
  /// Bez tohohle seznam pod prstem bliká zpátky na starší obsah.
  int _issued = 0;
  int _rendered = 0;

  List<TransitStop> _results = const <TransitStop>[];
  bool _loading = false;
  String? _error;
  bool _searched = false;

  /// Zjišťuje se až při prvním prázdném výsledku, a jen jednou. Prázdná
  /// databáze je stav, který nastane jednou v životě projektu; ptát se na něj
  /// při každém hledání by byl dotaz navíc při každém stisku klávesy.
  bool _dataMissing = false;
  bool _dataChecked = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounce?.cancel();
    final String q = raw.trim();
    if (q.length < _kMinQuery) {
      setState(() {
        _results = const <TransitStop>[];
        _loading = false;
        _error = null;
        _searched = false;
      });
      return;
    }
    // Jen když se stav opravdu mění. Po prvním písmenu už kostra svítí, takže
    // `setState(() => _loading = true)` na každý další znak přestavuje celý
    // sheet i se seznamem výsledků, aby nastavil true na true.
    if (!_loading) setState(() => _loading = true);
    _debounce = Timer(_kDebounce, () => _run(q));
  }

  Future<void> _run(String query) async {
    final int seq = ++_issued;
    try {
      final List<TransitStop> found = await ref
          .read(stopSearchRepositoryProvider)
          .search(query, near: widget.near);
      if (!mounted || seq < _rendered) return;
      _rendered = seq;
      setState(() {
        _results = found;
        _loading = false;
        _error = null;
        _searched = true;
      });
      if (found.isEmpty && !_dataChecked) {
        _dataChecked = true;
        final bool ready =
            await ref.read(stopSearchRepositoryProvider).hasData();
        if (!mounted) return;
        setState(() => _dataMissing = !ready);
      }
    } on Failure catch (e) {
      if (!mounted || seq < _rendered) return;
      _rendered = seq;
      setState(() {
        _loading = false;
        _error = errorText(e);
        _searched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Sp.xl,
        right: Sp.xl,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(widget.title, style: context.texts.titleLarge),
          const SizedBox(height: Sp.sm),
          // Křížek se překresluje sám, celý sheet ne.
          //
          // Bylo tu `setState(() {})` v onChanged, jen aby se objevilo a
          // zmizelo tlačítko Smazat. Přestavovalo to ale i seznam výsledků
          // pod sebou, a to na každé písmeno, zatímco ještě dojíždí animace
          // klávesnice. Debounce chránil síť, ne vykreslování.
          //
          // ValueListenableBuilder poslouchá controller přímo, takže rebuild
          // končí uvnitř pole.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (BuildContext context, TextEditingValue v, Widget? _) {
              return TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: widget.hint ?? 'Praha hl.n.',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: v.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Smazat',
                          onPressed: () {
                            _controller.clear();
                            _onChanged('');
                          },
                        ),
                ),
                onChanged: _onChanged,
              );
            },
          ),
          const SizedBox(height: Sp.sm),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: _body(context),
          ),
          const SizedBox(height: Sp.xs),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) {
      return PtErrorState(
        message: _error!,
        onRetry: () => _run(_controller.text.trim()),
      );
    }
    if (_controller.text.trim().length < _kMinQuery) {
      return const _Hint(
        icon: Icons.keyboard_outlined,
        text: 'Napište část názvu zastávky nebo nádraží. '
            'Na diakritice nezáleží.',
      );
    }
    // Kostra, ne kolečko: nad seznamem se z ní pozná, že se něco chystá,
    // a nepřeskočí layout, až výsledky dorazí.
    if (_loading && _results.isEmpty) {
      return ListView(
        shrinkWrap: true,
        children: const <Widget>[
          _StopSkeleton(),
          _StopSkeleton(),
          _StopSkeleton(),
        ],
      );
    }
    if (_results.isEmpty && _searched) {
      return _Hint(
        icon: _dataMissing
            ? Icons.cloud_download_outlined
            : Icons.search_off_outlined,
        text: _dataMissing
            ? 'Databáze zastávek zatím není naimportovaná. '
                'Spusťte tool/transit_import/import_stops.py.'
            : 'Nic takového jsme nenašli. Zkuste jiný tvar názvu — '
                'třeba jen jméno obce.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (BuildContext context, int i) =>
          _StopTile(stop: _results[i]),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({required this.stop});

  final TransitStop stop;

  @override
  Widget build(BuildContext context) {
    final String subtitle = stop.subtitle;
    final String? distance = stop.distanceKm == null
        ? null
        : stop.distanceKm! < 10
            ? '${stop.distanceKm!.toStringAsFixed(1)} km'
            : '${stop.distanceKm!.round()} km';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon(stop.mode), color: context.colors.primary),
      title: Text(stop.name),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: distance == null
          ? null
          : Text(
              distance,
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
      onTap: () => Navigator.of(context).pop(stop),
    );
  }

  static IconData _icon(StopMode m) => switch (m) {
        StopMode.train => Icons.train_outlined,
        StopMode.metro => Icons.subway_outlined,
        StopMode.tram => Icons.tram_outlined,
        StopMode.trolleybus => Icons.directions_bus_outlined,
        StopMode.bus => Icons.directions_bus_outlined,
        StopMode.ferry => Icons.directions_boat_outlined,
        StopMode.funicular => Icons.cable_outlined,
        StopMode.cablecar => Icons.cable_outlined,
        StopMode.other => Icons.place_outlined,
      };
}

class _StopSkeleton extends StatelessWidget {
  const _StopSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: Sp.sm),
      child: Row(
        children: <Widget>[
          PtSkeleton(height: 24, width: 24),
          SizedBox(width: Sp.md),
          Expanded(child: PtSkeleton(height: 16)),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: context.colors.onSurfaceVariant),
          const SizedBox(height: Sp.sm),
          Text(
            text,
            textAlign: TextAlign.center,
            style: context.texts.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
