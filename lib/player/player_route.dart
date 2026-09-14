import 'package:flutter/material.dart';

class PlayerSlideRoute<T> extends PageRouteBuilder<T> {
  PlayerSlideRoute({required Widget page})
      : super(
          opaque: true,
          barrierColor: Colors.black,
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
              child: FadeTransition(opacity: curved, child: child),
            );
          },
        );
}
