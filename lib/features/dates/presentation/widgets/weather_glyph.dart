import 'package:flutter/material.dart';

/// WMO 4677 weather codes, as Open-Meteo reports them, mapped to an icon and
/// a Czech phrase.
///
/// Colour is never the only signal (architecture section 7.4), so the glyph
/// and the words carry the meaning and the colour only reinforces it. The
/// buckets are coarse on purpose: "mrholení" and "slabý déšť" are the same
/// decision.
IconData wmoIcon(int? code) => switch (code) {
      0 => Icons.wb_sunny_outlined,
      1 || 2 => Icons.wb_cloudy_outlined,
      3 => Icons.cloud_outlined,
      45 || 48 => Icons.foggy,
      51 || 53 || 55 || 56 || 57 => Icons.grain,
      61 || 63 || 65 || 66 || 67 => Icons.water_drop_outlined,
      71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
      80 || 81 || 82 => Icons.umbrella_outlined,
      95 || 96 || 99 => Icons.thunderstorm_outlined,
      _ => Icons.help_outline,
    };

String wmoLabel(int? code) => switch (code) {
      0 => 'jasno',
      1 => 'skoro jasno',
      2 => 'polojasno',
      3 => 'zataženo',
      45 || 48 => 'mlha',
      51 || 53 || 55 => 'mrholení',
      56 || 57 => 'mrznoucí mrholení',
      61 || 63 => 'déšť',
      65 => 'silný déšť',
      66 || 67 => 'mrznoucí déšť',
      71 || 73 => 'sněžení',
      75 => 'silné sněžení',
      77 => 'sněhové krupky',
      80 || 81 => 'přeháňky',
      82 => 'silné přeháňky',
      85 || 86 => 'sněhové přeháňky',
      95 => 'bouřka',
      96 || 99 => 'bouřka s kroupami',
      _ => 'neznámo',
    };
