import 'package:flutter/material.dart';

import '../../../../core/design_system/components/components.dart';
import '../../domain/activity_tag.dart';

/// Diacritics-insensitive fold for search.
///
/// Somebody typing "vinarstvi" with one hand on a tram means Vinařství, and a
/// search that answers "nothing found" because of a háček is a search that
/// gets used once. Only the letters Czech actually needs — a full Unicode
/// normalisation would pull in a dependency to solve a problem this list of
/// twenty-nine words does not have.
String foldCz(String s) {
  const String from = 'áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ';
  const String to = 'acdeeinorstuuyzACDEINORSTUUYZ';
  final StringBuffer out = StringBuffer();
  for (final int rune in s.toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    final int i = from.indexOf(ch);
    out.write(i == -1 ? ch : to[i]);
  }
  return out.toString();
}

/// The compact field that stands in for twenty-nine chips.
///
/// The form used to render every section inline. It was honest and it was
/// unusable: six headings and twenty-nine chips pushed the budget field and
/// the create button below the fold, on the one screen whose whole promise is
/// "a trip in under sixty seconds". Selection is a *sometimes* task; the
/// screen should cost nothing when it is skipped, which is most of the time.
///
/// So: what you picked, and one way in. Nothing selected costs one line.
class ActivityField extends StatelessWidget {
  const ActivityField({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final Set<ActivityTag> selected;
  final ValueChanged<Set<ActivityTag>> onChanged;

  Future<void> _open(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ActivityPickerSheet(
        selected: selected,
        // Live, not on close. A sheet dismissed by swiping down returns null,
        // and losing eight taps to a gesture people make without thinking is
        // not a trade worth making for a tidier signature.
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (selected.isEmpty) {
      return OutlinedButton.icon(
        onPressed: () => _open(context),
        icon: const Icon(Icons.add),
        label: const Text('Vybrat aktivity'),
      );
    }

    final List<ActivityTag> shown = selected.toList()
      ..sort((ActivityTag a, ActivityTag b) => a.index.compareTo(b.index));

    return Wrap(
      spacing: Sp.xs,
      runSpacing: Sp.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (final ActivityTag t in shown)
          InputChip(
            label: Text(t.label),
            // Removable here as well as in the sheet: dropping one wrong tag
            // should not mean opening a whole screen to do it.
            onDeleted: () => onChanged(<ActivityTag>{...selected}..remove(t)),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('Další'),
          onPressed: () => _open(context),
        ),
      ],
    );
  }
}

/// Search plus categories, full height.
///
/// Both, not one or the other. Search wins when you know the word — "moře" is
/// two letters and a guess away — and categories win when you do not, which is
/// most people opening this for the first time. Offering only search assumes
/// the user already knows what the app offers.
class ActivityPickerSheet extends StatefulWidget {
  const ActivityPickerSheet({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final Set<ActivityTag> selected;
  final ValueChanged<Set<ActivityTag>> onChanged;

  @override
  State<ActivityPickerSheet> createState() => _ActivityPickerSheetState();
}

class _ActivityPickerSheetState extends State<ActivityPickerSheet> {
  late final Set<ActivityTag> _selected = <ActivityTag>{...widget.selected};
  String _query = '';

  /// Rozbalené sekce.
  ///
  /// Se 73 aktivitami je rozbalené všechno stejná zeď, jakou byl kdysi jeden
  /// plochý `Wrap` — jen delší. Otevřené jsou proto na začátku jen sekce, ve
  /// kterých už něco vybraného je; kdo nemá nic, uvidí šest nadpisů a rozhodne
  /// se, kam se vůbec dívat.
  late final Set<ActivitySection> _open = <ActivitySection>{
    for (final ActivitySection s in ActivitySection.values)
      if (ActivityTag.inSection(s).any(_selected.contains)) s,
  };

  void _toggle(ActivityTag t) {
    setState(() {
      if (!_selected.remove(t)) _selected.add(t);
    });
    widget.onChanged(<ActivityTag>{..._selected});
  }

  bool _matches(ActivityTag t) {
    if (_query.trim().isEmpty) return true;
    final String q = foldCz(_query.trim());
    return foldCz(t.label).contains(q) || foldCz(t.section.label).contains(q);
  }

  /// Jedna sbalitelná sekce.
  ///
  /// Při hledání je vždy otevřená: filtr už seznam zkrátil sám a nechat
  /// výsledek schovaný za klepnutím by znamenalo hledat dvakrát.
  Widget _section(BuildContext context, ActivitySection s, bool searching) {
    final List<ActivityTag> tags = <ActivityTag>[
      for (final ActivityTag t in ActivityTag.inSection(s))
        if (!searching || _matches(t)) t,
    ];
    final int chosen = tags.where(_selected.contains).length;
    final bool open = searching || _open.contains(s);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: searching
              ? null
              : () => setState(() {
                    if (!_open.remove(s)) _open.add(s);
                  }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.sm),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(s.label, style: context.texts.titleSmall),
                ),
                // Počet vybraných uvnitř. Bez něj se po sbalení nedá poznat,
                // jestli v sekci něco je — a to je celý smysl sbalování.
                if (chosen > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Sp.xs,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: context.colors.primaryContainer,
                      borderRadius: Radii.pillAll,
                    ),
                    child: Text(
                      '$chosen',
                      style: context.texts.labelSmall?.copyWith(
                        color: context.colors.onPrimaryContainer,
                      ),
                    ),
                  )
                else
                  Text(
                    '${tags.length}',
                    style: context.texts.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                if (!searching) ...<Widget>[
                  const SizedBox(width: Sp.xs),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: context.colors.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.xs),
            child: Wrap(
              spacing: Sp.xs,
              runSpacing: Sp.xs,
              children: <Widget>[
                for (final ActivityTag t in tags)
                  FilterChip(
                    label: Text(t.label),
                    selected: _selected.contains(t),
                    onSelected: (_) => _toggle(t),
                  ),
              ],
            ),
          ),
        Divider(height: 1, color: context.planto.hairline),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool searching = _query.trim().isNotEmpty;
    final List<ActivitySection> sections = ActivitySection.values
        .where((ActivitySection s) => ActivityTag.inSection(s).any(_matches))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext context, ScrollController scroll) {
        return Padding(
          padding: EdgeInsets.only(
            left: Sp.md,
            right: Sp.md,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: Sp.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Co chcete dělat?',
                      style: context.texts.titleLarge,
                    ),
                  ),
                  if (_selected.isNotEmpty)
                    Text(
                      'Vybráno ${_selected.length}',
                      style: context.texts.labelMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Sp.xs),
              TextField(
                // Not autofocused, unlike the destination sheet. There the
                // list is 22 place names and typing is the fast path; here the
                // categories are the point, and a keyboard covering half of
                // them on open hides the thing the user came to read.
                decoration: const InputDecoration(
                  hintText: 'Hledat aktivitu',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (String v) => setState(() => _query = v),
              ),
              const SizedBox(height: Sp.sm),
              Expanded(
                child: sections.isEmpty
                    ? const _NoMatch()
                    : ListView(
                        controller: scroll,
                        children: <Widget>[
                          // Vybrané nahoře a pohromadě. Jinak je jediný způsob,
                          // jak zjistit, co už mám, projít všech šest sekcí —
                          // a odebrat něco znamená to nejdřív najít.
                          if (!searching && _selected.isNotEmpty) ...<Widget>[
                            Padding(
                              padding: const EdgeInsets.only(bottom: Sp.xxs),
                              child: Text(
                                'Vybrané',
                                style: context.texts.labelMedium?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Wrap(
                              spacing: Sp.xs,
                              runSpacing: Sp.xs,
                              children: <Widget>[
                                for (final ActivityTag t in _selected.toList()
                                  ..sort(
                                    (ActivityTag a, ActivityTag b) =>
                                        a.label.compareTo(b.label),
                                  ))
                                  InputChip(
                                    label: Text(t.label),
                                    onDeleted: () => _toggle(t),
                                  ),
                              ],
                            ),
                            const Divider(height: Sp.xl),
                          ],
                          for (final ActivitySection s in sections)
                            _section(context, s, searching),
                          const SizedBox(height: Sp.md),
                        ],
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.sm),
                  child: PtButton(
                    label: 'Hotovo',
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.lg),
        child: Text(
          'Nic takového tu není. Aktivity slouží jen k tomu, aby seznam na '
          'sbalení a počasí seděly — když si nevyberete, výlet funguje dál.',
          textAlign: TextAlign.center,
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ),
    );
  }
}
