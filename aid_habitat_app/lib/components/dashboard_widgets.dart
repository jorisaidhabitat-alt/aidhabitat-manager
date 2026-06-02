import 'package:flutter/material.dart';

class NextVisitCard extends StatelessWidget {
  const NextVisitCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Prochaine visite",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text("NOM Prénom", style: TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(
            "47 Avenue des lorem ipsum 35250 Lorem",
            style: TextStyle(color: Color(0xFF2B323A)),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "XX XX XX XX XX",
                style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
              ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF597E8D),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text("Accéder"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class WeeklyVisitsWidget extends StatelessWidget {
  const WeeklyVisitsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Visites de la semaine",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _DayColumn(day: "L", date: "6", hasVisit: false),
              _DayColumn(day: "M", date: "7", hasVisit: true, visitCount: 2),
              _DayColumn(day: "M", date: "8", hasVisit: true, visitCount: 1),
              _DayColumn(day: "J", date: "9", hasVisit: false),
              _DayColumn(day: "V", date: "10", hasVisit: false),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  final String day;
  final String date;
  final bool hasVisit;
  final int visitCount;

  const _DayColumn({
    required this.day,
    required this.date,
    this.hasVisit = false,
    this.visitCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(day, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text(date, style: TextStyle(fontSize: 16, color: Colors.blueGrey.shade300)),
        const SizedBox(height: 8),
        if (hasVisit)
          Column(
            children: List.generate(visitCount, (index) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF597E8D),
                  shape: BoxShape.circle,
                ),
              ),
            )),
          )
        else
          const SizedBox(height: 12), // Placeholder to keep alignment
      ],
    );
  }
}

class PendingReportsWidget extends StatelessWidget {
  const PendingReportsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Rapports en attente",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          _ReportItem(name: "NOM Prénom"),
          _ReportItem(name: "NOM Prénom"),
          _ReportItem(name: "NOM Prénom"),
          _ReportItem(name: "NOM Prénom"),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF597E8D),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text("Voir la liste"),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportItem extends StatelessWidget {
  final String name;

  const _ReportItem({required this.name});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(name, style: const TextStyle(fontSize: 14)),
    );
  }
}
