// Text cleaning utilities to improve OCR speech output.

class CleanTextResult {
  const CleanTextResult({
    required this.formattedText,
    required this.canonicalText,
    required this.isAlert,
  });

  final String formattedText;
  final String canonicalText;
  final bool isAlert;

  static const empty = CleanTextResult(
    formattedText: '',
    canonicalText: '',
    isAlert: false,
  );
}

class TextCleaner {
  const TextCleaner();

  CleanTextResult clean(String rawText) {
    if (rawText.trim().isEmpty) {
      return CleanTextResult.empty;
    }

    final List<String> processed = <String>[];
    final lines = rawText.split(RegExp(r'[\r\n]+'));
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final cleanedLine = _formatSentence(line);
      if (cleanedLine.isNotEmpty) {
        processed.add(cleanedLine);
      }
    }

    if (processed.isEmpty) {
      return CleanTextResult.empty;
    }

    var joined = processed.join(' ').trim();
    if (joined.isEmpty) {
      return CleanTextResult.empty;
    }

    final isAlert = _containsAlert(joined);
    if (isAlert) {
      joined = _formatAlert(joined);
    }

    return CleanTextResult(
      formattedText: joined,
      canonicalText: joined,
      isAlert: isAlert,
    );
  }

  String _formatSentence(String input) {
    var text = _restoreSeparatedLetters(input);
    text = _normalizeWhitespace(text);
    text = _normalizeNumbers(text);
    text = text.trim();
    if (text.isEmpty) {
      return '';
    }

    if (_looksAllCaps(text)) {
      text = text.toLowerCase();
    }

    text = _capitalize(text);
    if (!_endsWithPunctuation(text)) {
      text = '$text.';
    }
    return text;
  }

  String _normalizeWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _restoreSeparatedLetters(String text) {
    final words = text.split(RegExp(r'\s+'));
    final buffer = StringBuffer();
    final current = <String>[];

    void flush() {
      if (current.isEmpty) return;
      if (current.length > 1) {
        buffer.write(current.join(''));
      } else {
        buffer.write(current.first);
      }
      buffer.write(' ');
      current.clear();
    }

    for (final word in words) {
      if (_isSingleLetter(word)) {
        current.add(word);
        continue;
      }
      flush();
      buffer.write('$word ');
    }
    flush();
    final result = buffer.toString().trim();
    return result.isEmpty ? text : result;
  }

  bool _isSingleLetter(String word) {
    return RegExp(r'^[A-ZÁÉÍÓÚÜÑ]$').hasMatch(word);
  }

  String _normalizeNumbers(String text) {
    var result = text;

    result = result.replaceAllMapped(_currencyPattern, (match) {
      final numeric = match.group(1)!;
      return _describeCurrency(numeric);
    });

    result = result.replaceAllMapped(RegExp(r'\b(\d+),(\d+)\b'), (match) {
      final whole = match.group(1)!;
      final decimals = match.group(2)!;
      return '$whole punto $decimals';
    });

    return result;
  }

  String _describeCurrency(String rawAmount) {
    final normalized = rawAmount.replaceAll(' ', '').replaceAll(',', '.');
    final value = double.tryParse(normalized);
    if (value == null) {
      return rawAmount;
    }

    final pesos = value.truncate();
    var cents = ((value - pesos) * 100).round();
    if (cents < 0) {
      cents = 0;
    }
    if (cents == 0) {
      return '$pesos pesos';
    }
    final padded = cents.toString().padLeft(2, '0');
    return '$pesos pesos con $padded centavos';
  }

  bool _looksAllCaps(String value) {
    final letters = RegExp(r'[A-ZÁÉÍÓÚÜÑa-záéíóúüñ]');
    final matches = letters.allMatches(value);
    if (matches.isEmpty) {
      return false;
    }
    return matches.every((match) {
      final char = match.group(0)!;
      return char == char.toUpperCase();
    });
  }

  String _capitalize(String text) {
    if (text.isEmpty) return text;
    final first = text.substring(0, 1).toUpperCase();
    if (text.length == 1) {
      return first;
    }
    return '$first${text.substring(1)}';
  }

  bool _endsWithPunctuation(String text) {
    return RegExp(r'[.!?¡¿]$').hasMatch(text);
  }

  bool _containsAlert(String text) {
    final lower = text.toLowerCase();
    return _alertKeywords.any((keyword) => lower.contains(keyword));
  }

  String _formatAlert(String text) {
    var content = text.trim();
    content = content.replaceFirst(RegExp(r'^peligro[:\s-]*', caseSensitive: false), '');
    content = content.trim();
    if (content.isEmpty) {
      return '¡Peligro!';
    }
    if (!_endsWithPunctuation(content)) {
      content = '$content.';
    }
    return '¡Peligro! $content';
  }

  static const List<String> _alertKeywords = <String>[
    'peligro',
    'prohibido',
    'zona de obras',
    'cuidado',
    'precaución',
    'alto',
    'advertencia',
    'alerta',
  ];

  static final RegExp _currencyPattern = RegExp(
    r'(?:US\$|USD|MXN|\$|S\/\.?|Q\.?|L\.?|€)\s*(\d+(?:[.,]\d{1,2})?)',
    caseSensitive: false,
  );
}
