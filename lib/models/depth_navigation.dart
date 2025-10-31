import 'dart:collection';

enum NavigationSector { left, center, right }

NavigationSector navigationSectorFromString(String? value) {
  switch (value?.toUpperCase()) {
    case 'L':
    case 'LEFT':
      return NavigationSector.left;
    case 'R':
    case 'RIGHT':
      return NavigationSector.right;
    case 'C':
    case 'CENTER':
    default:
      return NavigationSector.center;
  }
}

class NavigationObstacle {
  const NavigationObstacle({
    required this.label,
    required this.sector,
    this.distanceMeters,
    this.isApproximate = false,
  });

  final String label;
  final NavigationSector sector;
  final double? distanceMeters;
  final bool isApproximate;

  factory NavigationObstacle.fromMap(Map<dynamic, dynamic> map) {
    return NavigationObstacle(
      label: (map['label'] as String?)?.trim() ?? 'obstáculo',
      sector: navigationSectorFromString(map['sector'] as String?),
      distanceMeters: (map['distanceMeters'] as num?)?.toDouble(),
      isApproximate: map['approximate'] == true,
    );
  }
}

class DepthNavigationResult {
  const DepthNavigationResult({
    required this.instruction,
    required List<NavigationObstacle> obstacles,
    this.usedDepth = false,
  }) : _obstacles = obstacles;

  final String instruction;
  final bool usedDepth;
  final List<NavigationObstacle> _obstacles;

  UnmodifiableListView<NavigationObstacle> get obstacles =>
      UnmodifiableListView(_obstacles);

  bool get hasInstruction => instruction.trim().isNotEmpty;

  factory DepthNavigationResult.fromMap(Map<dynamic, dynamic> map) {
    final obstaclesRaw = map['obstacles'];
    final obstacles = <NavigationObstacle>[];
    if (obstaclesRaw is Iterable) {
      for (final entry in obstaclesRaw) {
        if (entry is Map) {
          obstacles.add(NavigationObstacle.fromMap(entry));
        }
      }
    }
    return DepthNavigationResult(
      instruction: (map['instruction'] as String?)?.trim() ?? '',
      obstacles: obstacles,
      usedDepth: map['usedDepth'] == true,
    );
  }
}
