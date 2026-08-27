import 'package:flutter/material.dart';
import '../home/home_page.dart';
import '../map/construction_map_page.dart';
import '../profile/profile_page.dart';
import '../surveys/surveys_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  static final shellKey = GlobalKey<MainShellState>();
  static void selectTab(int value) => shellKey.currentState?.selectTab(value);
  @override
  State<MainShell> createState() => MainShellState();
}

class MainShellState extends State<MainShell> {
  int index = 0;
  void selectTab(int value) => setState(() => index = value);
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(onSurveysTap: () => selectTab(1)),
      const SurveysPage(),
      const ConstructionMapPage(),
      const ProfilePage(),
    ];
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'INICIO',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'LEVANTAMIENTOS',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'MAPA',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'PERFIL',
          ),
        ],
      ),
    );
  }
}
