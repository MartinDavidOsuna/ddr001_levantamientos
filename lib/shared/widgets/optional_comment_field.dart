import 'package:flutter/material.dart';

class OptionalCommentField extends StatelessWidget {
  const OptionalCommentField({
    super.key,
    required this.initialValue,
    required this.enabled,
    required this.onChanged,
  });

  final String? initialValue;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 8),
    child: TextFormField(
      key: const Key('optional_comment_field'),
      initialValue: initialValue,
      enabled: enabled,
      maxLength: 2000,
      minLines: 2,
      maxLines: 4,
      decoration: const InputDecoration(
        labelText: 'Comentario opcional',
        floatingLabelBehavior: FloatingLabelBehavior.auto,
        alignLabelWithHint: true,
        contentPadding: EdgeInsets.fromLTRB(16, 20, 16, 14),
        border: OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );
}
