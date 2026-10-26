import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/dates.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../data/dashboard_models.dart';

/// Graphiques de l'accueil (demande MEDMEDBEN du 2026-10-05) : courbes et
/// anneaux animés (`fl_chart`), en NOIR ET GRIS depuis la maquette du
/// 2026-10-26 (« pas beaucoup de couleur »). Chaque graphique
/// porte un résumé lisible (lecteur d'écran, et quand il n'y a rien à tracer).

const _animation = Duration(milliseconds: 650);
const _curve = Curves.easeOutCubic;

/// Montant compact pour les axes : « 12,5 k », « 1,2 M » (DA).
String compactDA(int centimes) {
  final da = centimes / 100;
  if (da.abs() >= 1000000) return '${(da / 1000000).toStringAsFixed(1)} M';
  if (da.abs() >= 1000) return '${(da / 1000).toStringAsFixed(1)} k';
  return da.toStringAsFixed(0);
}

/// Carte de graphique : titre, sous-titre (le chiffre clé), contenu.
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AmpereType.h4.copyWith(color: colors.ink)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: AmpereType.meta.copyWith(color: colors.ink3),
              ),
            ],
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

/// Courbe du CA des 30 derniers jours : ligne lissée, remplissage en dégradé,
/// point final (aujourd'hui) mis en valeur, infobulle au toucher.
class RevenueTrendChart extends StatelessWidget {
  const RevenueTrendChart({super.key, required this.days});

  final List<DashboardDay> days;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final total = days.fold<int>(0, (s, d) => s + d.revenueTtc);
    final top = days.fold<int>(
      0,
      (m, d) => d.revenueTtc > m ? d.revenueTtc : m,
    );
    final maxY = top <= 0 ? 1.0 : top * 1.15;
    final spots = [
      for (final (i, d) in days.indexed)
        FlSpot(i.toDouble(), d.revenueTtc.toDouble()),
    ];

    return Semantics(
      label:
          'Chiffre d’affaires des ${days.length} derniers jours : '
          '${formatDA(total)} au total.',
      excludeSemantics: true,
      child: Container(
        height: 190,
        // Marge droite : la date d'aujourd'hui n'est pas coupée au bord.
        padding: const EdgeInsets.only(right: 18),
        child: LineChart(
          duration: _animation,
          curve: _curve,
          LineChartData(
            minY: days.any((d) => d.revenueTtc < 0)
                ? days
                      .map((d) => d.revenueTtc)
                      .reduce((a, b) => a < b ? a : b)
                      .toDouble()
                : 0,
            maxY: maxY,
            gridData: FlGridData(
              drawVerticalLine: false,
              horizontalInterval: maxY / 4,
              getDrawingHorizontalLine: (_) =>
                  FlLine(color: colors.lineSoft, strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: maxY / 4,
                  getTitlesWidget: (value, meta) => value == meta.max
                      ? const SizedBox.shrink()
                      : Text(
                          compactDA(value.round()),
                          style: AmpereType.meta.copyWith(color: colors.ink3),
                        ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 7,
                  reservedSize: 24,
                  getTitlesWidget: (value, meta) {
                    final i = value.round();
                    final last = days.length - 1;
                    // Une date par semaine, et aujourd'hui ; jamais deux
                    // étiquettes collées (la dernière semaine et aujourd'hui).
                    if (i < 0 ||
                        i > last ||
                        (i != last && (i % 7 != 0 || last - i < 4))) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        formatIsoDay(days[i].day).split('/').take(2).join('/'),
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    );
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => colors.surface3,
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(
                      '${formatIsoDay(days[s.x.round()].day)}\n'
                      '${formatDA(s.y.round())}',
                      AmpereType.meta.copyWith(color: colors.ink),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                preventCurveOverShooting: true,
                barWidth: 2,
                color: colors.ink,
                dotData: FlDotData(
                  checkToShowDot: (spot, _) => spot.x == days.length - 1,
                  getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                    radius: 5,
                    color: colors.ink,
                    strokeWidth: 2,
                    strokeColor: colors.surface,
                  ),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.ink.withValues(alpha: 0.10),
                      colors.ink.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Meilleurs produits sur 30 jours : barres horizontales en dégradé, la
/// première en accent, montant et quantité en clair.
class TopProductsChart extends StatelessWidget {
  const TopProductsChart({super.key, required this.products});

  final List<DashboardTopProduct> products;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    if (products.isEmpty) {
      return Text(
        'Aucune vente sur la période.',
        style: AmpereType.meta.copyWith(color: colors.ink3),
      );
    }
    final top = products.first.revenueTtc <= 0 ? 1 : products.first.revenueTtc;
    return Column(
      children: [
        for (final (i, p) in products.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(
              label:
                  '${i + 1}. ${p.name} : ${formatDA(p.revenueTtc)}, '
                  'quantité ${p.quantity}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${i + 1}. ${p.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AmpereType.bodyStrong.copyWith(
                            color: colors.ink,
                          ),
                        ),
                      ),
                      Text(
                        formatDA(p.revenueTtc),
                        style: AmpereType.bodyStrong.copyWith(
                          color: colors.ink,
                          fontFeatures: AmpereType.tabular,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Barre animée à l'apparition (de 0 à sa part du meilleur).
                  TweenAnimationBuilder<double>(
                    tween: Tween(
                      begin: 0,
                      end: (p.revenueTtc / top).clamp(0.0, 1.0),
                    ),
                    duration: _animation + Duration(milliseconds: 90 * i),
                    curve: _curve,
                    builder: (context, value, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        children: [
                          Container(height: 8, color: colors.surface2),
                          FractionallySizedBox(
                            widthFactor: value,
                            // Le premier en noir plein, les suivants en gris.
                            child: Container(
                              height: 8,
                              color: i == 0 ? colors.ink : colors.ink3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// État du stock en anneau : sains / sous le seuil / épuisés, total au centre.
class StockHealthDonut extends StatelessWidget {
  const StockHealthDonut({super.key, required this.stock});

  final DashboardStock stock;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // « Sous le seuil » compte aussi les épuisés : on les sépare pour l'anneau.
    final out = stock.outOfStockCount;
    final low = (stock.lowCount - out).clamp(0, stock.lowCount);
    final ok = stock.okCount;
    final total = ok + low + out;
    final parts = [
      ('Sains', ok, colors.ink),
      ('Sous le seuil', low, colors.ink3),
      ('Épuisés', out, colors.surface3),
    ];

    return Semantics(
      label:
          'État du stock : $ok sains, $low sous le seuil, $out épuisés '
          'sur $total produits.',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            width: 170,
            height: 170,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  duration: _animation,
                  curve: _curve,
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 52,
                    startDegreeOffset: -90,
                    sections: [
                      if (total == 0)
                        PieChartSectionData(
                          value: 1,
                          color: colors.surface3,
                          radius: 26,
                          showTitle: false,
                        )
                      else
                        for (final (_, count, color) in parts)
                          if (count > 0)
                            PieChartSectionData(
                              value: count.toDouble(),
                              color: color,
                              radius: 26,
                              showTitle: false,
                            ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$total',
                      style: AmpereType.h2.copyWith(color: colors.ink),
                    ),
                    Text(
                      'produits',
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (label, count, color) in parts)
                Column(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(color: colors.line),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          label.toUpperCase(),
                          style: AmpereType.label.copyWith(color: colors.ink3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count',
                      style: AmpereType.h4.copyWith(
                        color: colors.ink,
                        fontFeatures: AmpereType.tabular,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
