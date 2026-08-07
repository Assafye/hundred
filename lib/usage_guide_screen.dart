import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'login_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

class UsageGuideScreen extends StatefulWidget {
  const UsageGuideScreen({
    super.key,
    this.returnToLoginOnExit = false,
    this.enableSwipeBack = true,
  });

  final bool returnToLoginOnExit;
  final bool enableSwipeBack;

  @override
  State<UsageGuideScreen> createState() => _UsageGuideScreenState();
}

class _UsageGuideScreenState extends State<UsageGuideScreen> {
  static const Color _bgTop = Color(0xFF0A1224);
  static const Color _bgBottom = Color(0xFF070B12);
  static const Color _cardTop = Color(0xFF182238);
  static const Color _cardBottom = Color(0xFF121A2B);
  static const Color _accentBlue = Color(0xFF53D9FF);
  static const Color _accentPurple = Color(0xFFA48BFF);
  static const Color _textPrimary = Color(0xFFF4F7FF);
  static const Color _textSecondary = Color(0xFFB8C3E0);
  final PageController _pageController = PageController();
  late final List<_GuidePageData> _pages;
  late final List<int> _selectedImagePerPage;

  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pages = _buildPages();
    _selectedImagePerPage = List<int>.filled(_pages.length, 0);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  List<_GuidePageData> _buildPages() {
    return const <_GuidePageData>[
      _GuidePageData(
        title: 'ברוכים הבאים ל-hundred',
        description:
            'חוברת קצרה שתעזור לכם להבין מהר איך האפליקציה עובדת ומה הכי חשוב להכיר כבר מההתחלה.',
      ),
      _GuidePageData(
        title: 'סרגל תחתון',
        description: 'בסרגל תוכלו לעבור בין העמודים הראשים של האפליקציה.',
        imageAssets: <String>['assets/guide/bottom_bar_1.jpg'],
      ),
      _GuidePageData(
        title: 'עמוד הפיד',
        description:
            'בעמוד הזה תוכלו לצפות במשימות שמשתמשים אחרים פרסמו, להוסיף לדירוג שלהם, לשתף ולשמור לכם. אתם יכולים לשלוט באיזה סוג פוסטים לצפות ואם להציג פוסטים של חברים או של כולם.',
        imageAssets: <String>[
          'assets/guide/feed_1.jpg',
          'assets/guide/feed_2.jpg',
        ],
      ),
      _GuidePageData(
        title: 'עמוד האונליין',
        description:
            'בעמוד זה תוכלו לגלות חברים חדשים סביבכם שמחפשים להיפגש, להצטרף לקבוצות שמתכננות לעשות משהו ביחד ולפרסם בעצמכם משהו שבא לכם לעשות כדי שמשתמשים אחרים יוכלו להצטרף אליכם.',
        imageAssets: <String>[
          'assets/guide/online_1.jpg',
          'assets/guide/online_2.jpg',
        ],
      ),
      _GuidePageData(
        title: 'מסך הפרופיל',
        description:
            'המסך הזה הוא מאגר הזכרונות שלכם. במסך זה תוכלו לצפות באיזה משימות כבר ביצעתם, מה הניקוד המצטבר שהגעתם אליו וכל המידע על הפרופיל שלכם.',
        imageAssets: <String>['assets/guide/profile_1.jpg'],
      ),
      _GuidePageData(
        title: 'מסך כוכבי השבוע',
        description:
            'במסך זה תראו את האתגר האישי שלכם, האתגר השבועי המתחלף לכל המשתמשים ואת הפוסטים עם הניקוד הגבוה ביותר מהשבוע האחרון.',
        imageAssets: <String>['assets/guide/stars_1.jpg'],
      ),
      _GuidePageData(
        title: 'מסך הצאטים',
        description:
            'במסך זה תוכלו להתכתב עם חברים ולמצוא קבוצות חדשות שמתכננות להיפגש ולהצטרף אליהן.',
        imageAssets: <String>[
          'assets/guide/chats_1.jpg',
          'assets/guide/chats_2.jpg',
        ],
      ),
      _GuidePageData(
        title: 'מסך הוספת פופ',
        description:
            'במסך זה תוכלו לפרסם משהו שבא לכם לעשות והוא יוצג למשך 24 שעות למשתמשים בקרבת מקום.',
        imageAssets: <String>['assets/guide/pop_1.jpg'],
      ),
      _GuidePageData(
        title: 'למה אתם מחכים? לכו תעשו משהו!',
        description:
            'זהו, אתם מוכנים לצאת לדרך. אפשר תמיד לחזור לחוברת דרך ההגדרות כדי לרענן זיכרון.',
      ),
    ];
  }

  Future<void> _exitGuide() async {
    if (!mounted) {
      return;
    }

    if (widget.returnToLoginOnExit) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
      return;
    }

    Navigator.of(context).maybePop();
  }

  void _goNext() {
    if (_currentPage >= _pages.length - 1) {
      _exitGuide();
      return;
    }

    _pageController.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _goPrevious() {
    if (_currentPage == 0) {
      return;
    }

    _pageController.previousPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _currentPage == _pages.length - 1;

    final body = Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[_bgTop, _bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _exitGuide,
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: _accentBlue,
                      ),
                      label: const Text(
                        'דלג על ההסבר',
                        style: TextStyle(
                          color: _accentBlue,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_currentPage + 1}/${_pages.length}',
                      style: const TextStyle(
                        color: _textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (index) {
                    setState(() {
                      _currentPage = index;
                    });
                  },
                  itemBuilder: (context, index) {
                    final page = _pages[index];
                    final selectedImageIndex = _selectedImagePerPage[index];
                    String? imageAsset;
                    if (page.imageAssets.isNotEmpty) {
                      final normalizedImageIndex = selectedImageIndex.clamp(
                        0,
                        page.imageAssets.length - 1,
                      );
                      imageAsset = page.imageAssets[normalizedImageIndex];
                    }

                    final isEdgePage = index == 0 || index == _pages.length - 1;

                    if (isEdgePage) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(26),
                            gradient: const LinearGradient(
                              colors: <Color>[_cardTop, _cardBottom],
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                            ),
                            border: Border.all(
                              color: _accentBlue.withValues(alpha: 0.22),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                page.title,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _textPrimary,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                page.description,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _textSecondary,
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Expanded(
                                child: Center(
                                  child: _GuideAnimatedLogo(size: 290),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(26),
                          gradient: const LinearGradient(
                            colors: <Color>[_cardTop, _cardBottom],
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                          ),
                          border: Border.all(
                            color: _accentBlue.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              page.title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: _textPrimary,
                                fontSize: 25,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              page.description,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: _textSecondary,
                                fontSize: 15,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (imageAsset != null) ...[
                              if (page.imageAssets.length > 1) ...[
                                _buildImageSelector(index, page.imageAssets),
                                const SizedBox(height: 12),
                              ],
                              _buildMainImage(imageAsset),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List<Widget>.generate(_pages.length, (index) {
                    final isSelected = index == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: isSelected ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: isSelected
                            ? _accentPurple
                            : _accentPurple.withValues(alpha: 0.28),
                      ),
                    );
                  }),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _currentPage == 0 ? null : _goPrevious,
                        icon: const Icon(Icons.chevron_left_rounded),
                        label: const Text('קודם'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: _accentBlue.withValues(alpha: 0.45),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: const LinearGradient(
                            colors: <Color>[_accentBlue, _accentPurple],
                            begin: Alignment.centerRight,
                            end: Alignment.centerLeft,
                          ),
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _goNext,
                          icon: Icon(
                            isLastPage
                                ? Icons.check_circle_rounded
                                : Icons.chevron_right_rounded,
                          ),
                          label: Text(isLastPage ? 'סיום' : 'הבא'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: widget.enableSwipeBack ? SwipeBackWrapper(child: body) : body,
    );
  }

  Widget _buildMainImage(String imageAsset) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 0.58,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFF172033), Color(0xFF111826)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Image.asset(
            imageAsset,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) {
              return Padding(
                padding: const EdgeInsets.all(14),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _accentBlue.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'התמונה לא נמצאה.\nאפשר להוסיף אותה לתיקיית\nassets/guide',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildImageSelector(int pageIndex, List<String> images) {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, imageIndex) {
          final isSelected = _selectedImagePerPage[pageIndex] == imageIndex;
          final imageAsset = images[imageIndex];

          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedImagePerPage[pageIndex] = imageIndex;
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: isSelected ? 88 : 76,
              padding: EdgeInsets.all(isSelected ? 2 : 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected
                      ? _accentBlue
                      : _accentBlue.withValues(alpha: 0.18),
                  width: isSelected ? 1.4 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  imageAsset,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF111827),
                    alignment: Alignment.center,
                    child: Text(
                      '${imageIndex + 1}',
                      style: const TextStyle(
                        color: _textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GuidePageData {
  const _GuidePageData({
    required this.title,
    required this.description,
    this.imageAssets = const <String>[],
  });

  final String title;
  final String description;
  final List<String> imageAssets;
}

class _GuideAnimatedLogo extends StatefulWidget {
  const _GuideAnimatedLogo({required this.size});

  final double size;

  @override
  State<_GuideAnimatedLogo> createState() => _GuideAnimatedLogoState();
}

class _GuideAnimatedLogoState extends State<_GuideAnimatedLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _gradientController;

  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat();
  }

  @override
  void dispose() {
    _gradientController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: _gradientController,
        builder: (context, _) {
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(46),
              gradient: const LinearGradient(
                colors: [Color(0xFF11111A), Color(0xFF05050B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: EdgeInsets.all(widget.size * 0.16),
            child: CustomPaint(
              painter: _GuideInfinityPainter(
                phase: _gradientController.value,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GuideInfinityPainter extends CustomPainter {
  const _GuideInfinityPainter({required this.phase});

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _buildInfinityPath(size);
    final angle = phase * math.pi * 2;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final center = Offset(size.width / 2, size.height / 2);
    final travel = Offset(dx, dy) * (size.width * 0.22);
    final gradientStart = center - travel;
    final gradientEnd = center + travel;

    final shader = const LinearGradient(
      colors: [
        Color(0xFF1EDCFF),
        Color(0xFF76D1FF),
        Color(0xFFC38CFF),
        Color(0xFF76D1FF),
        Color(0xFF1EDCFF),
      ],
      stops: [0.0, 0.24, 0.5, 0.76, 1.0],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Rect.fromPoints(gradientStart, gradientEnd));

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = size.width * 0.068
      ..shader = shader;

    canvas.drawPath(path, paint);
  }

  Path _buildInfinityPath(Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final a = size.width * 0.42;
    final yScale = a;
    const pointCount = 360;

    final path = Path();
    for (var i = 0; i <= pointCount; i++) {
      final t = (i / pointCount) * math.pi * 2;
      final sinT = math.sin(t);
      final cosT = math.cos(t);
      final d = 1 + sinT * sinT;

      final x = cx + a * cosT / d;
      final y = cy + yScale * sinT * cosT / d;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    final centerLineHalf = size.height * 0.27;
    path
      ..moveTo(cx, cy - centerLineHalf)
      ..lineTo(cx, cy + centerLineHalf);

    return path;
  }

  @override
  bool shouldRepaint(covariant _GuideInfinityPainter oldDelegate) {
    return oldDelegate.phase != phase;
  }
}
