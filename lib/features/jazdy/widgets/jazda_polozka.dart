import 'package:flutter/material.dart';

import '../../../models/jazda.dart';

class JazdaPolozka extends StatelessWidget {
  const JazdaPolozka({required this.jazda, this.onTap, super.key});

  final Jazda jazda;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jeSluzobna = jazda.typ == TypJazdy.sluzobna;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: jeSluzobna
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.tertiaryContainer,
          child: Icon(
            jeSluzobna ? Icons.business_center_outlined : Icons.person_outline,
            color: jeSluzobna
                ? theme.colorScheme.onSecondaryContainer
                : theme.colorScheme.onTertiaryContainer,
          ),
        ),
        title: Text('${jazda.odkial}  →  ${jazda.kam}'),
        subtitle: Text(
          '${jazda.zaciatok} – ${jazda.koniec} • ${jazda.typ.nazov}',
        ),
        trailing: Text(
          '${jazda.kilometre.toStringAsFixed(1)} km',
          style: theme.textTheme.titleSmall,
        ),
      ),
    );
  }
}
