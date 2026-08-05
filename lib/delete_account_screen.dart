import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'login_screen.dart';
import 'services/auth_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  static const Color _bgTop = Colors.white;
  static const Color _bgBottom = Colors.white;
  static const Color _darkBgTop = Color(0xFF10162A);
  static const Color _darkBgBottom = Color(0xFF0B1019);
  static const Color _cardTop = Color(0xFF172437);
  static const Color _cardBottom = Color(0xFF231C3F);
  static const Color _accentCyan = Color(0xFF53C1F9);
  static const Color _accentPurple = Color(0xFF9E7CFF);

  final TextEditingController _reasonController = TextEditingController();
  final AuthService _authService = AuthService();
  bool _confirmedIntent = false;
  bool _isDeleting = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submitDeletion() async {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty || _isDeleting) {
      if (reason.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('יש לכתוב בקצרה למה החלטת למחוק את החשבון.')),
        );
      }
      return;
    }

    setState(() {
      _isDeleting = true;
    });

    try {
      await _authService.deleteCurrentAccount(deletionReason: reason);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } on FirebaseAuthException catch (error) {
      if (!mounted) {
        return;
      }
      final message = error.code == 'requires-recent-login'
          ? 'כדי למחוק חשבון צריך להתחבר מחדש. התחבר/י שוב ואז נסה/י מחיקה.'
          : 'מחיקת החשבון נכשלה: ${error.message ?? error.code}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

      if (error.code == 'requires-recent-login') {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
        return;
      }

      setState(() {
        _isDeleting = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('מחיקת החשבון נכשלה: $error')),
      );
      setState(() {
        _isDeleting = false;
      });
    }
  }

  Widget _buildCard({required bool isLight}) {
    final titleColor = isLight ? Colors.black : Colors.white;
    final bodyColor =
        isLight ? const Color(0xFF46536D) : const Color(0xFFBCD0ED);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: isLight ? Colors.white.withOpacity( 0.72) : null,
        gradient: isLight
            ? null
            : LinearGradient(
                colors: [
                  _cardTop.withOpacity( 0.95),
                  _cardBottom.withOpacity( 0.95),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
        border: Border.all(
          color:
              isLight ? const Color(0xFFA9C3FF) : _accentCyan.withOpacity( 0.24),
        ),
        boxShadow: [
          BoxShadow(
            color: isLight
                ? _accentCyan.withOpacity( 0.08)
                : Colors.black.withOpacity( 0.22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  isLight ? const Color(0xFFFFEEF1) : const Color(0xFF341B26),
              border: Border.all(
                color: isLight
                    ? const Color(0xFFFFB6C6)
                    : const Color(0xFFFF7F9C).withOpacity( 0.35),
              ),
            ),
            child: Icon(
              Icons.delete_forever_rounded,
              color:
                  isLight ? const Color(0xFFD44D73) : const Color(0xFFFF8AAA),
              size: 30,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'מחיקת חשבון',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: titleColor,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _confirmedIntent
                ? 'לפני שנמחק את החשבון, נשמח להבין מה הוביל אותך להחלטה הזאת.'
                : 'החשבון יסומן כמחוק, והפרופיל הציבורי יוסתר. לייקים, תגובות ופוסטים קיימים יישארו תחת משתמש מחוק.',
            textAlign: TextAlign.right,
            textDirection: TextDirection.rtl,
            style: TextStyle(
              color: bodyColor,
              height: 1.45,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 18),
          if (!_confirmedIntent) ...[
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: titleColor,
                side: BorderSide(
                  color: isLight
                      ? const Color(0xFFA9C3FF)
                      : _accentCyan.withOpacity( 0.24),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'לא, חזרה להגדרות',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _confirmedIntent = true;
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isLight ? const Color(0xFFFFD7E1) : const Color(0xFF7A1E3A),
                foregroundColor:
                    isLight ? const Color(0xFF822744) : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'כן, המשך למחיקה',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ] else ...[
            TextField(
              controller: _reasonController,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.right,
              minLines: 4,
              maxLines: 6,
              style: TextStyle(color: titleColor),
              decoration: InputDecoration(
                hintText: 'למה?',
                hintStyle: TextStyle(
                  color: isLight ? Colors.black45 : Colors.white38,
                ),
                filled: true,
                fillColor: isLight
                    ? Colors.white.withOpacity( 0.92)
                    : const Color(0xFF101A2B),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: isLight
                        ? const Color(0xFFFFC2D0)
                        : const Color(0xFFFF7F9C).withOpacity( 0.26),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: isLight
                        ? const Color(0xFFFFC2D0)
                        : const Color(0xFFFF7F9C).withOpacity( 0.26),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: isLight
                        ? const Color(0xFFD44D73)
                        : const Color(0xFFFF8AAA),
                    width: 1.3,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: _isDeleting
                  ? null
                  : () {
                      setState(() {
                        _confirmedIntent = false;
                      });
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: titleColor,
                side: BorderSide(
                  color: isLight
                      ? const Color(0xFFA9C3FF)
                      : _accentCyan.withOpacity( 0.24),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'חזרה',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _isDeleting ? null : _submitDeletion,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isLight ? const Color(0xFFD44D73) : const Color(0xFFFF8AAA),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _isDeleting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'מחק את החשבון',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.62).clamp(180.0, 220.0);
    final orbSizeB = (screenWidth * 0.72).clamp(200.0, 260.0);
    final titleColor = isLight ? Colors.black : Colors.white;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
        backgroundColor: isLight ? _bgBottom : _darkBgBottom,
        appBar: AppBar(
          backgroundColor:
              isLight ? const Color(0xFFCFEFFF) : const Color(0xFF131E31),
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: titleColor),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'מחיקת חשבון',
            style: TextStyle(color: titleColor, fontWeight: FontWeight.w800),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isLight
                        ? const [_bgTop, _bgBottom]
                        : const [_darkBgTop, Color(0xFF131B33), _darkBgBottom],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
            Positioned(
              top: -70,
              right: -45,
              child: Container(
                width: orbSizeA,
                height: orbSizeA,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      (isLight ? _accentCyan : _accentCyan).withOpacity( 0.09),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -50,
              child: Container(
                width: orbSizeB,
                height: orbSizeB,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isLight ? _accentPurple : _accentPurple)
                      .withOpacity( 0.08),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: SingleChildScrollView(
                  child: _buildCard(isLight: isLight),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
