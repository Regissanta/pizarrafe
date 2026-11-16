class FinanceEntry {
  FinanceEntry({
    required this.id,
    required this.kind,
    required this.period,
    required this.date,
    required this.amount,
    required this.category,
    required this.description,
    this.paymentMethod,
    this.memberId,
    this.memberName,
  });

  final String id;
  final String kind;
  final String period;
  final DateTime date;
  final int amount;
  final String category;
  final String description;
  final String? paymentMethod;
  final String? memberId;
  final String? memberName;

  bool get isIncome => kind == 'dues' || kind == 'pledge' || kind == 'visits';
  bool get isExpense => kind == 'expense';

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'period': period,
    'date': date.toIso8601String(),
    'amount': amount,
    'category': category,
    'description': description,
    'paymentMethod': paymentMethod,
    'memberId': memberId,
    'memberName': memberName,
  };

  factory FinanceEntry.fromJson(Map<String, dynamic> json) => FinanceEntry(
    id: json['id'] as String,
    kind: json['kind'] as String,
    period: json['period'] as String,
    date: DateTime.parse(json['date'] as String),
    amount: json['amount'] as int,
    category: json['category'] as String,
    description: json['description'] as String? ?? '',
    paymentMethod: json['paymentMethod'] as String?,
    memberId: json['memberId'] as String?,
    memberName: json['memberName'] as String?,
  );
}

String financePeriod(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

List<String> financePeriodChoices(DateTime date) => [
  financePeriod(DateTime(date.year, date.month)),
  financePeriod(DateTime(date.year, date.month + 1)),
];

String financePeriodLabel(String period) {
  final parts = period.split('-');
  if (parts.length != 2) return period;
  const months = [
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  if (year == null || month == null || month < 1 || month > 12) return period;
  final name = months[month - 1];
  return '${name[0].toUpperCase()}${name.substring(1)} $year';
}

String formatPesos(int amount) {
  final digits = amount.abs().toString();
  final grouped = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
    grouped.write(digits[index]);
  }
  final sign = amount < 0 ? '-' : '';
  return 'RD\$ $sign$grouped';
}

String buildMemberDuesWhatsAppMessage({
  required String leagueName,
  required String memberId,
  required String memberName,
  required String period,
  required int monthlyDues,
  required int received,
  required List<FinanceEntry> payments,
}) {
  final memberPayments =
      payments
          .where(
            (entry) =>
                entry.kind == 'dues' &&
                entry.period == period &&
                entry.memberId == memberId,
          )
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  final pending = (monthlyDues - received).clamp(0, monthlyDues);
  final paymentLines =
      memberPayments.isEmpty
          ? ['No hay pagos registrados este mes.']
          : memberPayments.map((entry) {
            final date =
                '${entry.date.day.toString().padLeft(2, '0')}/'
                '${entry.date.month.toString().padLeft(2, '0')}/'
                '${entry.date.year}';
            final method = switch (entry.paymentMethod) {
              'cash' => ' · Efectivo',
              'deposit' => ' · Depósito',
              _ => '',
            };
            return '• $date: ${formatPesos(entry.amount)}$method';
          }).toList();

  return [
    'Hola $memberName,',
    'Resumen de cuota de $leagueName · ${financePeriodLabel(period)}',
    'Cuota mensual: ${formatPesos(monthlyDues)}',
    'Pagos registrados:',
    ...paymentLines,
    'Total abonado: ${formatPesos(received)}',
    if (pending > 0)
      'Pendiente: ${formatPesos(pending)}'
    else
      'Estado: cuota completa',
    if (received > monthlyDues)
      'Excedente: ${formatPesos(received - monthlyDues)}',
  ].join('\n');
}

String buildLeagueDuesWhatsAppMessage({
  required String leagueName,
  required String period,
  required int monthlyDues,
  required List<({String name, int received})> members,
}) {
  final totalExpected = members.length * monthlyDues;
  final totalReceived = members.fold(
    0,
    (total, member) => total + member.received,
  );
  return [
    'Resumen de cuotas · $leagueName · ${financePeriodLabel(period)}',
    ...members.map((member) {
      final pending = (monthlyDues - member.received).clamp(0, monthlyDues);
      return '• ${member.name}: abonado ${formatPesos(member.received)}'
          '${pending > 0 ? ' · pendiente ${formatPesos(pending)}' : ' · completo'}';
    }),
    'Total recibido: ${formatPesos(totalReceived)} de '
        '${formatPesos(totalExpected)} esperados',
  ].join('\n');
}

Uri whatsAppShareUri(String message) =>
    Uri.https('wa.me', '/', {'text': message});
