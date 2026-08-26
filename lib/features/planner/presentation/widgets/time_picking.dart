/// Výběr času pro plán.
///
/// Vrací **naivní místní čas** na tomtéž dni, jako má výchozí hodnota. To je
/// celý důvod, proč to není přímo `showTimePicker` na místě použití: čas
/// v plánu je nástěnná hodina v zóně výletu, ne okamžik v zóně telefonu, a
/// překlad na okamžik dělá engine — jediný, kdo zná posun zóny.
library;

import 'package:flutter/material.dart';

Future<DateTime?> pickLocalTime(BuildContext context, DateTime? seed) async {
  final DateTime base = seed ?? DateTime.now();
  final TimeOfDay? picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: base.hour, minute: base.minute),
  );
  if (picked == null) return null;
  return DateTime(base.year, base.month, base.day, picked.hour, picked.minute);
}
