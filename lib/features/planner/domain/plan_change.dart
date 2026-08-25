/// Co uživatel s plánem udělal.
///
/// Sealed, protože engine na tom dělá exhaustivní switch a přidání nového
/// druhu úpravy má být chyba překladu, ne tichá větev `default:`, která
/// nedělá nic.
///
/// Časy jsou v místních nástěnných hodinách. Uživatel vybírá „ve dvanáct",
/// ne okamžik, a překlad na okamžik je práce enginu — ten jediný zná posun
/// zóny výletu.
library;

import 'package:flutter/foundation.dart';

import 'journey.dart';
import 'plan_item.dart';

/// Klíč titulku, který si uživatel pojmenoval sám.
const String kNamedItemKey = 'plan.named';

sealed class PlanChange {
  const PlanChange();
}

/// Postav plán od začátku. Používá se při prvním otevření záložky a když
/// uživatel řekne „vygeneruj znovu".
@immutable
final class BuildPlan extends PlanChange {
  const BuildPlan();
}

/// „Vyrazím nejdřív v…"
@immutable
final class SetDepartAfter extends PlanChange {
  const SetDepartAfter(this.localTime);
  final DateTime localTime;
}

/// „Chci být na místě do…" — ovlivňuje cestu tam a všechno, co na ní visí.
@immutable
final class SetArriveBy extends PlanChange {
  const SetArriveBy(this.localTime);
  final DateTime localTime;
}

/// „Chci být doma nejpozději v…" — ovlivňuje cestu zpět, cestu tam ne.
@immutable
final class SetHomeBy extends PlanChange {
  const SetHomeBy(this.localTime);
  final DateTime localTime;
}

/// „Vyrazíme zpátky v…" — druhý konec téhož rozhodnutí než [SetHomeBy].
///
/// Skupina obvykle ví, kolik času chce strávit v cíli; čas návratu domů z
/// toho teprve plyne. Proto to je vlastní zadání, ne dopočet — a proto ruší
/// [SetHomeBy], aby se cesta zpět nehledala podle dvou různých čísel.
@immutable
final class SetLeaveAt extends PlanChange {
  const SetLeaveAt(this.localTime);
  final DateTime localTime;
}

/// Zruš zadaný požadavek. Nastavit ho zpátky na výchozí čas není totéž jako
/// ho zrušit: první je rozhodnutí, druhé je jeho absence.
@immutable
final class ClearConstraints extends PlanChange {
  const ClearConstraints({
    this.departAfter = false,
    this.arriveBy = false,
    this.homeBy = false,
    this.leaveAt = false,
  });

  final bool departAfter;
  final bool arriveBy;
  final bool homeBy;
  final bool leaveAt;
}

/// Posuň položku na jiný čas při zachované délce.
@immutable
final class MoveItem extends PlanChange {
  const MoveItem(this.itemId, this.localStart);
  final String itemId;
  final DateTime localStart;
}

/// Změň délku položky při zachovaném začátku.
@immutable
final class ResizeItem extends PlanChange {
  const ResizeItem(this.itemId, this.duration);
  final String itemId;
  final Duration duration;
}

/// Jedna úprava položky ze sheetu — čas, délka, název, poznámka a zámek
/// najednou.
///
/// Jedna změna, ne čtyři. Kdyby sheet posílal každé pole zvlášť, běžel by
/// přepočet i uložení čtyřikrát za jedno klepnutí na „Uložit" a uživatel by
/// viděl osu poskakovat.
///
/// Null pole znamená „neměň", ne „vymaž".
@immutable
final class EditItem extends PlanChange {
  const EditItem(
    this.itemId, {
    this.localStart,
    this.duration,
    this.title,
    this.note,
    this.locked,
  });

  final String itemId;
  final DateTime? localStart;
  final Duration? duration;
  final String? title;
  final String? note;
  final bool? locked;
}

/// Zamkni nebo odemkni. Zamčenou položku engine nesmí posunout ani vyměnit.
@immutable
final class SetItemLocked extends PlanChange {
  const SetItemLocked(this.itemId, {required this.locked});
  final String itemId;
  final bool locked;
}

/// Vlastní bod na ose.
@immutable
final class AddItem extends PlanChange {
  const AddItem(this.item);
  final PlanItem item;
}

/// Úprava obsahu položky (název, poznámka, cena). Časy mění [MoveItem]
/// a [ResizeItem] — kdyby to uměl i tenhle, byly by na posun dvě cesty
/// a jedna z nich by zapomněla přepočítat zbytek.
@immutable
final class UpdateItem extends PlanChange {
  const UpdateItem(this.item);
  final PlanItem item;
}

@immutable
final class RemoveItem extends PlanChange {
  const RemoveItem(this.itemId);
  final String itemId;
}

/// Uživatel si vybral konkrétní spoj ze seznamu.
///
/// Tím se z položek toho úseku stane [PlanItemSource.userSelected] a zamknou
/// se. Vyměnit je pak smí jenom další vědomá volba — automatický přepočet na
/// ně sáhnout nesmí a musí to říct.
@immutable
final class ChooseJourney extends PlanChange {
  const ChooseJourney(this.segment, this.journey);
  final PlanSegment segment;
  final Journey journey;
}

/// Přepočítej jeden úsek znovu, i když je zamčený. Vzniká z tlačítka
/// „Hledat jiný spoj", tedy z výslovného přání — proto smí přebít zámek.
@immutable
final class RefreshSegment extends PlanChange {
  const RefreshSegment(this.segment);
  final PlanSegment segment;
}

/// Žádná změna — jenom dohledej, co zbylo.
///
/// Vzniká ve druhém kole přepočtu: první kolo posunulo aktivitu a zjistilo,
/// že na původní spoj domů se už nestíhá. Druhé kolo ten spoj dohledá a nic
/// jiného nedělá.
@immutable
final class NoChange extends PlanChange {
  const NoChange();
}
