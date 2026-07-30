import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/components/components.dart';
import 'routes.dart';

/// Bottom-nav shell. Three tabs, not five — Chat and Plan live inside a trip
/// because they have no meaning outside one (architecture section 6).
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({required this.state, required this.child, super.key});

  final GoRouterState state;
  final Widget child;

  static const List<String> _paths = <String>[
    Routes.trips,
    Routes.discover,
    Routes.profile,
  ];

  int get _index {
    final int i = _paths.indexWhere(
      (String path) => state.matchedLocation.startsWith(path),
    );
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final bool expanded =
        Breakpoints.isExpanded(MediaQuery.sizeOf(context).width);

    // Tablets and foldables get a rail. This is also what makes the V2 web
    // build cheap (architecture section 7.5).
    if (expanded) {
      return Scaffold(
        body: Row(
          children: <Widget>[
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (int i) => context.go(_paths[i]),
              labelType: NavigationRailLabelType.all,
              destinations: const <NavigationRailDestination>[
                NavigationRailDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: Text('Výlety'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.explore_outlined),
                  selectedIcon: Icon(Icons.explore),
                  label: Text('Objevovat'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: Text('Profil'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int i) => context.go(_paths[i]),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Výlety',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: 'Objevovat',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
