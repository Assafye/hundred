import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../services/camera_permission_service.dart';
import '../../services/face_verification_service.dart';
import 'face_verification_pose.dart';

class FaceVerificationScreen extends StatefulWidget {
  const FaceVerificationScreen({
    super.key,
    this.onVerified,
    this.showExistingUserNotice = false,
  });

  final VoidCallback? onVerified;
  final bool showExistingUserNotice;

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen>
    with WidgetsBindingObserver {
  static const int _requiredStableFrames = 5;
  static const Duration _frameInterval = Duration(milliseconds: 180);
  static const Color _backgroundTop = Color(0xFF7471D8);
  static const Color _backgroundBottom = Color(0xFF58A9D0);
  static const Color _surface = Color(0xFF1B1B20);
  static const Color _accent = Color(0xFF53C1F9);
  static const Color _stepPurple = Color(0xFF8D73E6);
  static const Color _stepPurpleComplete = Color(0xFF7257C7);
  static const Color _stepPurpleInactive = Color(0x66725AAB);
  static const Color _pending = Color(0xFFF87B4F);
  static const Color _ready = Color(0xFF4CD97B);

  final FaceVerificationService _verificationService =
      FaceVerificationService();
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableTracking: true,
      minFaceSize: 0.2,
    ),
  );
  final List<XFile> _captures = <XFile>[];

  CameraController? _cameraController;
  CameraDescription? _camera;
  DateTime _lastProcessedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _currentStep = 0;
  int _stableFrames = 0;
  bool _isInitializing = true;
  bool _isProcessingFrame = false;
  bool _isCapturing = false;
  bool _isUploading = false;
  bool _poseReady = false;
  String? _errorMessage;

  FaceVerificationPose get _pose => FaceVerificationPose.values[_currentStep];

  String get _instruction {
    switch (_pose) {
      case FaceVerificationPose.front:
        return 'מבט ישר למצלמה';
      case FaceVerificationPose.right:
        return 'סובב/י את הראש ימינה';
      case FaceVerificationPose.left:
        return 'סובב/י את הראש שמאלה';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.showExistingUserNotice) {
        await _showExistingUserNotice();
      }
      if (mounted) await _initializeCamera();
    });
  }

  Future<void> _showExistingUserNotice() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 28),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 410),
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              decoration: BoxDecoration(
                color: const Color(0xFF171822),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _accent.withValues(alpha: 0.32),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 62,
                    height: 62,
                    decoration: const BoxDecoration(
                      color: _stepPurple,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.verified_user_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'הוספנו אמצעי אבטחה לאפליקציה, יש לבצע אימות בכדי להמשיך להשתמש בבטחה',
                    textAlign: TextAlign.center,
                    style:
                        Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                            ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: _stepPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('המשך לאימות'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _cameraController;
    _cameraController = null;
    unawaited(controller?.dispose());
    unawaited(_faceDetector.close());
    _deleteCaptures();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_disposeCamera());
      return;
    }
    if (state == AppLifecycleState.resumed &&
        !_isUploading &&
        _cameraController == null) {
      unawaited(_initializeCamera());
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    _isProcessingFrame = false;
    if (mounted) setState(() {});
    await controller?.dispose();
  }

  Future<void> _initializeCamera() async {
    if (!mounted || _isUploading) return;
    setState(() {
      _isInitializing = true;
      _errorMessage = null;
      _poseReady = false;
      _stableFrames = 0;
    });

    try {
      final hasPermission =
          await CameraPermissionService.ensureCameraAccess(context);
      if (!hasPermission) {
        throw CameraException(
          'CameraAccessDenied',
          'נדרשת הרשאת מצלמה כדי להשלים את האימות.',
        );
      }
      if (!mounted) return;

      final cameras = await availableCameras();
      final frontCameras = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      if (frontCameras.isEmpty) {
        throw CameraException(
          'NoFrontCamera',
          'לא נמצאה מצלמה קדמית במכשיר.',
        );
      }

      _camera = frontCameras.first;
      final controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      try {
        await controller.setFlashMode(FlashMode.off);
      } on CameraException {
        // Some front cameras do not expose flash controls; capture still works.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }

      _cameraController = controller;
      await controller.startImageStream(_processCameraImage);
      if (!mounted) return;
      setState(() => _isInitializing = false);
    } catch (error) {
      await _disposeCamera();
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = _describeError(error);
      });
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingFrame || _isCapturing || _isUploading || !mounted) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastProcessedAt) < _frameInterval) return;
    _lastProcessedAt = now;
    _isProcessingFrame = true;

    try {
      final frameInput = _inputImageFromCameraImage(image);
      if (frameInput == null) {
        _updatePoseState(false);
        return;
      }
      final faces = await _faceDetector.processImage(frameInput.image);
      if (!mounted || _isCapturing || _isUploading) return;

      final face = faces.singleOrNull;
      final isValid = face != null &&
          isFaceVerificationPoseValid(
            pose: _pose,
            boundingBox: face.boundingBox,
            imageSize: frameInput.processedSize,
            yaw: face.headEulerAngleY,
            roll: face.headEulerAngleZ,
          );
      _updatePoseState(isValid);

      if (isValid && _stableFrames >= _requiredStableFrames) {
        await _capturePose();
      }
    } catch (_) {
      _updatePoseState(false);
    } finally {
      _isProcessingFrame = false;
    }
  }

  _CameraFrameInput? _inputImageFromCameraImage(CameraImage image) {
    final camera = _camera;
    final controller = _cameraController;
    if (camera == null || controller == null || image.planes.length != 1) {
      return null;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    if (format == null) return null;

    final rotation = _imageRotation(
      camera,
      controller.value.deviceOrientation,
    );
    if (rotation == null) return null;

    final isQuarterTurn = rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final processedSize = isQuarterTurn
        ? Size(image.height.toDouble(), image.width.toDouble())
        : Size(image.width.toDouble(), image.height.toDouble());

    return _CameraFrameInput(
      processedSize: processedSize,
      image: InputImage.fromBytes(
        bytes: image.planes.first.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      ),
    );
  }

  InputImageRotation? _imageRotation(
    CameraDescription camera,
    DeviceOrientation orientation,
  ) {
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    }

    const orientationDegrees = <DeviceOrientation, int>{
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final deviceDegrees = orientationDegrees[orientation];
    if (deviceDegrees == null) return null;
    final rotationDegrees = camera.lensDirection == CameraLensDirection.front
        ? (camera.sensorOrientation + deviceDegrees) % 360
        : (camera.sensorOrientation - deviceDegrees + 360) % 360;
    return InputImageRotationValue.fromRawValue(rotationDegrees);
  }

  void _updatePoseState(bool isValid) {
    if (!mounted || _isCapturing || _isUploading) return;
    final nextStableFrames = isValid ? _stableFrames + 1 : 0;
    final nextReady = isValid;
    if (nextStableFrames == _stableFrames && nextReady == _poseReady) return;
    setState(() {
      _stableFrames = nextStableFrames;
      _poseReady = nextReady;
    });
  }

  Future<void> _capturePose() async {
    final controller = _cameraController;
    if (controller == null || _isCapturing || !controller.value.isInitialized) {
      return;
    }

    _isCapturing = true;
    if (mounted) setState(() {});
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final capture = await controller.takePicture();
      _captures.add(capture);

      if (_captures.length == FaceVerificationPose.values.length) {
        await _uploadVerification();
        return;
      }

      if (!mounted) return;
      setState(() {
        _currentStep += 1;
        _stableFrames = 0;
        _poseReady = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted && controller.value.isInitialized) {
        await controller.startImageStream(_processCameraImage);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _describeError(error));
    } finally {
      _isCapturing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _uploadVerification() async {
    if (!mounted) return;
    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      await _verificationService.uploadAndFinalize(_captures);
      if (!mounted) return;
      widget.onVerified?.call();
      if (widget.onVerified == null && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _errorMessage = _describeError(error);
      });
    }
  }

  Future<void> _retry() async {
    if (_isUploading || _isCapturing) return;
    setState(() => _errorMessage = null);
    if (_captures.length == 3) {
      await _uploadVerification();
      return;
    }
    await _disposeCamera();
    await _initializeCamera();
  }

  void _deleteCaptures() {
    for (final capture in _captures) {
      unawaited(
          File(capture.path).delete().catchError((_) => File(capture.path)));
    }
  }

  String _describeError(Object error) {
    if (error is CameraException) {
      return error.description ?? 'לא הצלחנו להפעיל את המצלמה.';
    }
    return 'האימות לא הושלם. בדוק/י את החיבור ונסה/י שוב.';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final isCameraReady = controller?.value.isInitialized == true;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _backgroundTop,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_backgroundTop, _backgroundBottom],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  child: Column(
                    children: [
                      Text(
                        'יש לאמת שאינך בוט.\nאימות זה נועד לשמור על חווית המשתמשים באפליקציה.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: Colors.white,
                              height: 1.45,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 20),
                      _StepIndicator(currentStep: _currentStep),
                      const SizedBox(height: 20),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: ColoredBox(
                            color: _surface,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (isCameraReady)
                                  _CameraPreviewCover(controller: controller!)
                                else
                                  const Center(
                                    child: CircularProgressIndicator(
                                      color: _accent,
                                    ),
                                  ),
                                CustomPaint(
                                  painter: _FaceGuidePainter(
                                    color: _poseReady ? _ready : _pending,
                                  ),
                                ),
                                Positioned(
                                  top: 16,
                                  left: 16,
                                  right: 16,
                                  child: Center(
                                    child: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 200),
                                      child: Container(
                                        key: ValueKey<String>(
                                          '${_currentStep}_${_poseReady}_$_isCapturing',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xCC171822),
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                            color:
                                                (_poseReady ? _ready : _pending)
                                                    .withValues(alpha: 0.55),
                                          ),
                                        ),
                                        child: Text(
                                          _poseReady
                                              ? 'מצוין, להישאר יציב/ה'
                                              : _instruction,
                                          textAlign: TextAlign.center,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                color: _poseReady
                                                    ? _ready
                                                    : Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'האימות מתבצע אוטומטית כשהתנוחה יציבה',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.white70,
                            ),
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('נסה/י שוב'),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_isUploading)
                  const Positioned.fill(child: _UploadingOverlay()),
                if (_isInitializing && !isCameraReady && _errorMessage == null)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Color(0x66000000)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraFrameInput {
  const _CameraFrameInput({
    required this.image,
    required this.processedSize,
  });

  final InputImage image;
  final Size processedSize;
}

class _CameraPreviewCover extends StatelessWidget {
  const _CameraPreviewCover({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return const SizedBox.shrink();
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewSize.height,
          height: previewSize.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.currentStep});

  final int currentStep;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      textDirection: TextDirection.rtl,
      children: List<Widget>.generate(3, (index) {
        final isComplete = index < currentStep;
        final isCurrent = index == currentStep;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: isCurrent ? 34 : 28,
            height: 28,
            decoration: BoxDecoration(
              color: isComplete
                  ? _FaceVerificationScreenState._stepPurpleComplete
                  : isCurrent
                      ? _FaceVerificationScreenState._stepPurple
                      : _FaceVerificationScreenState._stepPurpleInactive,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: isComplete
                ? const Icon(Icons.check_rounded, size: 17, color: Colors.white)
                : Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        );
      }),
    );
  }
}

class _UploadingOverlay extends StatelessWidget {
  const _UploadingOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xEE121214),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(
                color: _FaceVerificationScreenState._accent,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'משלימים את האימות...',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()..color = const Color(0x66000000);
    final headPath = _headOutline(size);
    final cutout = Path()
      ..addRect(Offset.zero & size)
      ..addPath(headPath, Offset.zero)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(cutout, overlayPaint);
    canvas.drawPath(
      headPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  Path _headOutline(Size size) {
    final centerX = size.width / 2;
    final top = size.height * 0.17;
    final templeY = size.height * 0.34;
    final cheekY = size.height * 0.61;
    final chinY = size.height * 0.79;
    final templeWidth = size.width * 0.34;
    final cheekWidth = size.width * 0.29;
    final jawWidth = size.width * 0.18;

    return Path()
      ..moveTo(centerX, top)
      ..cubicTo(
        centerX + templeWidth * 0.72,
        top,
        centerX + templeWidth,
        templeY * 0.86,
        centerX + templeWidth,
        templeY,
      )
      ..cubicTo(
        centerX + templeWidth,
        size.height * 0.48,
        centerX + cheekWidth,
        cheekY,
        centerX + jawWidth,
        size.height * 0.7,
      )
      ..cubicTo(
        centerX + jawWidth * 0.68,
        size.height * 0.75,
        centerX + jawWidth * 0.38,
        chinY,
        centerX,
        chinY,
      )
      ..cubicTo(
        centerX - jawWidth * 0.38,
        chinY,
        centerX - jawWidth * 0.68,
        size.height * 0.75,
        centerX - jawWidth,
        size.height * 0.7,
      )
      ..cubicTo(
        centerX - cheekWidth,
        cheekY,
        centerX - templeWidth,
        size.height * 0.48,
        centerX - templeWidth,
        templeY,
      )
      ..cubicTo(
        centerX - templeWidth,
        templeY * 0.86,
        centerX - templeWidth * 0.72,
        top,
        centerX,
        top,
      )
      ..close();
  }

  @override
  bool shouldRepaint(covariant _FaceGuidePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
