import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'models/post_media_item.dart';
import 'post_edit_screen.dart';
import 'profile_screen.dart';
import 'services/camera_permission_service.dart';
import 'widgets/swipe_back_wrapper.dart';
import 'video_preview_utils.dart';

class CreatePostScreen extends StatefulWidget {
  final String? initialCategory;
  final String? initialSubCategory;

  const CreatePostScreen({
    super.key,
    this.initialCategory,
    this.initialSubCategory,
  });

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen>
    with WidgetsBindingObserver {
  static const int _maxMediaItems = 10;
  static const int _maxVideoRecordingSeconds = 60;

  CameraController? _cameraController;
  Future<void>? _initializeControllerFuture;
  bool _isCameraReady = false;
  bool _isSwitchingCamera = false;
  bool _isCameraOperationInProgress = false;
  bool _isTransitioning = false;
  bool _isRecordingVideo = false;
  bool _isProcessingCapture = false;
  bool _isFrontCamera = false;
  bool _flashEnabled = false;
  bool _isWhiteScreenFlashActive = false;
  double _whiteScreenFlashAlpha = 0;
  String? _cameraError;
  Timer? _recordingLimitTimer;

  final ImagePicker _imagePicker = ImagePicker();
  final List<PostUploadMediaItem> _selectedMediaItems = <PostUploadMediaItem>[];

  bool get _canAddMoreMedia => _selectedMediaItems.length < _maxMediaItems;

  void _logCamera(String event, [Object? details]) {
    if (!kDebugMode) {
      return;
    }

    final buffer = StringBuffer('[CameraFlow] $event');
    if (details != null) {
      buffer.write(' | $details');
    }
    debugPrint(buffer.toString());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _logCamera('initState -> adding lifecycle observer');
  }

  @override
  void dispose() {
    _logCamera('dispose -> removing observer and tearing down camera');
    WidgetsBinding.instance.removeObserver(this);

    // Block new lifecycle/init work while the state is being destroyed.
    _isCameraOperationInProgress = true;
    final controller = _cameraController;
    _detachCameraState();
    controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logCamera(
      'lifecycle -> state=$state | isSwitchingCamera=$_isSwitchingCamera | operationInProgress=$_isCameraOperationInProgress | hasController=${_cameraController != null} | initialized=${_cameraController?.value.isInitialized ?? false} | ready=$_isCameraReady',
    );

    if (_isCameraOperationInProgress) {
      _logCamera('lifecycle -> ignore event while camera operation is locked');
      return;
    }

    final controller = _cameraController;
    final hasActiveController =
        controller != null && controller.value.isInitialized;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _logCamera('lifecycle -> pausing app, disposing camera controller');
      unawaited(_disposeCameraController());
      return;
    }

    if (state == AppLifecycleState.resumed && !hasActiveController) return;
  }

  void _detachCameraState({bool resetReadyState = true}) {
    _logCamera(
      '_detachCameraState -> resetting camera state | resetReadyState=$resetReadyState | oldController=${_cameraController != null}',
    );
    _recordingLimitTimer?.cancel();
    _recordingLimitTimer = null;
    _cameraController = null;
    _initializeControllerFuture = null;
    _isSwitchingCamera = false;
    if (resetReadyState) {
      _isCameraReady = false;
    }
    _isRecordingVideo = false;
  }

  Future<void> _detachCameraStateAndRebuild({bool resetReadyState = true}) async {
    if (!mounted) {
      _detachCameraState(resetReadyState: resetReadyState);
      return;
    }

    setState(() => _detachCameraState(resetReadyState: resetReadyState));
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _disposeCameraController({bool resetReadyState = true}) async {
    if (_isCameraOperationInProgress) {
      _logCamera('_disposeCameraController -> skipped because another camera operation is running');
      return;
    }

    // Lock camera mutations until the active controller is fully torn down.
    _isCameraOperationInProgress = true;
    final controller = _cameraController;
    _logCamera(
      '_disposeCameraController -> start | controllerPresent=${controller != null} | resetReadyState=$resetReadyState',
    );

    try {
      await _detachCameraStateAndRebuild(resetReadyState: resetReadyState);
      if (controller == null) {
        _logCamera('_disposeCameraController -> nothing to dispose');
        return;
      }

      await controller.dispose();
      _logCamera('_disposeCameraController -> disposed old controller');
    } catch (_) {
      _logCamera('_disposeCameraController -> dispose threw, ignoring race');
      // Ignore disposal races when external pickers temporarily background the app.
    } finally {
      _isCameraOperationInProgress = false;
    }
  }

  Future<void> _initializeCamera() async {
    if (_isCameraOperationInProgress) {
      _logCamera('_initializeCamera -> skipped because another camera operation is running');
      return;
    }

    // Lock camera initialization so lifecycle and manual actions cannot overlap.
    _isCameraOperationInProgress = true;
    _logCamera(
      '_initializeCamera -> start | front=$_isFrontCamera | currentController=${_cameraController != null} | isSwitching=$_isSwitchingCamera',
    );

    final oldController = _cameraController;

    try {
      if (oldController != null) {
        if (mounted) {
          setState(() {
            _cameraController = null;
            _initializeControllerFuture = null;
            _isCameraReady = false;
            _isSwitchingCamera = true;
            _cameraError = null;
          });
        } else {
          _cameraController = null;
          _initializeControllerFuture = null;
          _isCameraReady = false;
          _isSwitchingCamera = true;
          _cameraError = null;
        }

        await oldController.dispose();
        _logCamera('_initializeCamera -> disposed existing controller before reinitializing');
      } else if (mounted) {
        setState(() {
          _cameraError = null;
          _isCameraReady = false;
          _isSwitchingCamera = true;
        });
      }

      final cameras = await availableCameras();
      _logCamera('_initializeCamera -> cameras discovered | count=${cameras.length}');
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cameraError = 'לא נמצאה מצלמה זמינה';
          _isCameraReady = false;
          _isSwitchingCamera = false;
        });
        _logCamera('_initializeCamera -> no cameras available');
        return;
      }

      final preferredDirection =
          _isFrontCamera ? CameraLensDirection.front : CameraLensDirection.back;
      final cameraDescription = cameras.firstWhere(
        (camera) => camera.lensDirection == preferredDirection,
        orElse: () {
          final fallback = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => cameras.first,
          );
          _isFrontCamera = fallback.lensDirection == CameraLensDirection.front;
          return fallback;
        },
      );

      _logCamera(
        '_initializeCamera -> selected camera | lens=${cameraDescription.lensDirection} | facingFront=$_isFrontCamera',
      );

      final controller = CameraController(
        cameraDescription,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      if (mounted) {
        setState(() {
          _cameraError = null;
          _isCameraReady = oldController != null && oldController.value.isInitialized;
          _isSwitchingCamera = true;
        });
      }

      _initializeControllerFuture = controller.initialize();
      await _initializeControllerFuture;
      _logCamera('_initializeCamera -> controller initialized');
      await _setFlashModeOff(controller);

      if (!mounted) {
        _logCamera('_initializeCamera -> mounted false, disposing new controller before return');
        await controller.dispose();
        return;
      }

      // Commit the new controller in one state update after initialization completes.
      setState(() {
        _cameraController = controller;
        _initializeControllerFuture = null;
        _isCameraReady = true;
        _cameraError = null;
        _isSwitchingCamera = false;
      });

      if (oldController != null && oldController != controller) {
        _logCamera('_initializeCamera -> previous controller already disposed before creating new one');
      }

      _logCamera('_initializeCamera -> success | ready=true');
    } catch (error) {
      var message = 'שגיאה בהפעלת המצלמה';
      if (error is CameraException) {
        final code = error.code.toLowerCase();
        if (code.contains('cameraaccessdenied') ||
            code.contains('cameraaccessdeniedwithoutprompt') ||
            code.contains('cameraaccessrestricted')) {
          message =
              'אין הרשאת מצלמה באייפון. אפשר לאשר בהגדרות > פרטיות ואבטחה > מצלמה.';
        } else if (code.contains('audioaccessdenied') ||
            code.contains('audioaccessrestricted')) {
          message =
              'אין הרשאת מיקרופון באייפון. אפשר לאשר בהגדרות > פרטיות ואבטחה > מיקרופון.';
        }
      }
      _logCamera('_initializeCamera -> failed | error=$error');
      if (!mounted) return;
      setState(() {
        _cameraError = message;
        _isCameraReady = false;
        _isSwitchingCamera = false;
      });
    } finally {
      _isCameraOperationInProgress = false;
      if (mounted && _cameraController != null && _cameraController!.value.isInitialized) {
        setState(() {
          _isCameraReady = true;
          _isSwitchingCamera = false;
        });
      } else if (mounted) {
        setState(() {
          _isSwitchingCamera = false;
        });
      }
    }
  }

  Future<void> _setFlashModeOff(CameraController controller) async {
    try {
      await controller.setFlashMode(FlashMode.off);
    } catch (_) {
      // Some devices/plugins may not support explicit flash mode updates.
    }
  }

  Future<void> _toggleCameraLens() async {
    if (_isCameraOperationInProgress) {
      return;
    }

    if (_isProcessingCapture || _isRecordingVideo || _isSwitchingCamera) {
      return;
    }

    // Lock the entire lens-switch sequence against re-entry.
    _isCameraOperationInProgress = true;
    setState(() {
      _isSwitchingCamera = true;
      _isTransitioning = true;
      _cameraError = null;
    });

    final currentController = _cameraController;
    final camerasFuture = availableCameras();

    try {
      final cameras = await camerasFuture;
      if (cameras.isEmpty) {
        return;
      }

      // Resolve the opposite lens before updating the active state.
      final nextIsFront = !_isFrontCamera;
      final preferredDirection =
          nextIsFront ? CameraLensDirection.front : CameraLensDirection.back;

      final cameraDescription = cameras.firstWhere(
        (camera) => camera.lensDirection == preferredDirection,
        orElse: () => cameras.first,
      );

      final resolvedIsFront =
          cameraDescription.lensDirection == CameraLensDirection.front;

      // Remove the old preview from state before disposing the controller.
      if (mounted) {
        setState(() {
          if (identical(_cameraController, currentController)) {
            _cameraController = null;
          }
          _initializeControllerFuture = null;
          _isCameraReady = false;
          _cameraError = null;
        });
      } else if (identical(_cameraController, currentController)) {
        _cameraController = null;
        _initializeControllerFuture = null;
        _isCameraReady = false;
        _cameraError = null;
      }

      // Dispose the current controller before initializing the next one.
      await currentController?.dispose();

      final newController = CameraController(
        cameraDescription,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      try {
        await newController.initialize();
        await _setFlashModeOff(newController);

        if (!mounted) {
          await newController.dispose();
          return;
        }

        // Commit the new controller only after it is fully ready for preview.
        setState(() {
          _isFrontCamera = resolvedIsFront;
          _cameraController = newController;
          _initializeControllerFuture = null;
          _isCameraReady = true;
          _cameraError = null;
          _isSwitchingCamera = false;
          _isTransitioning = false;
        });
      } catch (_) {
        await newController.dispose();
        rethrow;
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Toggle lens failed: $error');
      }
      if (mounted) {
        setState(() {
          _cameraError = 'שגיאה בהחלפת המצלמה';
          _isSwitchingCamera = false;
          _isTransitioning = false;
          _isCameraReady = false;
        });
      }
    } finally {
      _isCameraOperationInProgress = false;
      if (mounted && (_isSwitchingCamera || _isTransitioning)) {
        setState(() {
          _isSwitchingCamera = false;
          _isTransitioning = false;
        });
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_isProcessingCapture) {
      return;
    }

    final controller = _cameraController;
    final nextFlashEnabled = !_flashEnabled;
    setState(() {
      _flashEnabled = nextFlashEnabled;
      _isWhiteScreenFlashActive = false;
      _whiteScreenFlashAlpha = 0;
    });

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      await controller.setFlashMode(FlashMode.off);
    } catch (_) {
      // Some devices/plugins do not support explicit flash mode changes.
    }
  }

  void _showLimitReachedSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('אפשר להוסיף עד 10 מדיות לפוסט אחד'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  Future<void> _capturePhoto() async {
    if (_isProcessingCapture || _isRecordingVideo) {
      return;
    }
    if (!_canAddMoreMedia) {
      _showLimitReachedSnackBar();
      return;
    }

    if (!await CameraPermissionService.ensureCameraAccess(context)) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      await _initializeCamera();
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() {
      _isProcessingCapture = true;
      _isWhiteScreenFlashActive = _flashEnabled && _isFrontCamera;
      _whiteScreenFlashAlpha =
          (_flashEnabled && _isFrontCamera) ? 0.9 : 0;
    });

    try {
      if (_flashEnabled && !_isFrontCamera) {
        try {
          await controller.setFlashMode(FlashMode.torch);
        } catch (_) {
          // Some devices/plugins may not support torch during capture.
        }
      }

      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      setState(() {
        _selectedMediaItems.add(
          PostUploadMediaItem(
            file: file,
            previewBytes: bytes,
            type: 'image',
          ),
        );
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('לא ניתן לצלם כעת'),
          backgroundColor: Colors.redAccent,
        ),
      );
      if (kDebugMode) {
        debugPrint('Capture failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isWhiteScreenFlashActive = false;
          _whiteScreenFlashAlpha = 0;
          _isProcessingCapture = false;
        });
      }

      if (!_isFrontCamera && _flashEnabled) {
        try {
          await controller.setFlashMode(FlashMode.off);
        } catch (_) {
          // Ignore unsupported flash reset.
        }
      }
    }
  }

  Future<void> _startVideoRecording() async {
    if (_isProcessingCapture || _isRecordingVideo) {
      return;
    }
    if (!_canAddMoreMedia) {
      _showLimitReachedSnackBar();
      return;
    }

    if (!await CameraPermissionService.ensureCameraAccess(context)) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      await _initializeCamera();
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      if (_flashEnabled) {
        if (!_isFrontCamera) {
          await controller.setFlashMode(FlashMode.torch);
        }
        setState(() {
          _isWhiteScreenFlashActive = _isFrontCamera;
          _whiteScreenFlashAlpha = _isFrontCamera ? 0.7 : 0;
        });
      } else {
        setState(() {
          _isWhiteScreenFlashActive = false;
          _whiteScreenFlashAlpha = 0;
        });
        await _setFlashModeOff(controller);
      }

      await controller.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _isRecordingVideo = true;
      });

      _recordingLimitTimer?.cancel();
      _recordingLimitTimer = Timer(
        const Duration(seconds: _maxVideoRecordingSeconds),
        () async {
          if (!mounted || !_isRecordingVideo) {
            return;
          }
          await _stopVideoRecording(reachedMaxDuration: true);
        },
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to start video recording: $error');
      }
    }
  }

  void _handleVideoRelease() {
    if (_isRecordingVideo) {
      _stopVideoRecording();
    }
  }

  Future<void> _stopVideoRecording({bool reachedMaxDuration = false}) async {
    final controller = _cameraController;
    if (controller == null || !_isRecordingVideo) {
      return;
    }

    _recordingLimitTimer?.cancel();
    _recordingLimitTimer = null;

    try {
      final file = await controller.stopVideoRecording();
      final previewBytes = await buildVideoPreviewBytes(file);
      if (!mounted) return;
      setState(() {
        _isRecordingVideo = false;
        _isWhiteScreenFlashActive = false;
        _whiteScreenFlashAlpha = 0;
        _selectedMediaItems.add(
          PostUploadMediaItem(
            file: file,
            previewBytes: previewBytes,
            type: 'video',
          ),
        );
      });
      if (reachedMaxDuration && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('הקלטת וידאו מוגבלת ל-60 שניות'),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isRecordingVideo = false;
        _isWhiteScreenFlashActive = false;
        _whiteScreenFlashAlpha = 0;
      });
      if (kDebugMode) {
        debugPrint('Failed to stop video recording: $error');
      }
    } finally {
      if (!_isFrontCamera && _flashEnabled) {
        try {
          await controller.setFlashMode(FlashMode.off);
        } catch (_) {
          // Ignore unsupported flash reset.
        }
      }
      if (mounted) {
        setState(() {
          _isWhiteScreenFlashActive = false;
          _whiteScreenFlashAlpha = 0;
        });
      }
    }
  }

  Future<void> _pickImagesFromGallery() async {
    if (!_canAddMoreMedia) {
      _showLimitReachedSnackBar();
      return;
    }

    await _disposeCameraController();

    try {
      final files = await _imagePicker.pickMultiImage();
      if (files.isEmpty) {
        return;
      }

      final remainingSlots = _maxMediaItems - _selectedMediaItems.length;
      final filesToAdd = files.take(remainingSlots).toList(growable: false);
      final pickedItems = <PostUploadMediaItem>[];

      for (final file in filesToAdd) {
        final bytes = await file.readAsBytes();
        pickedItems.add(
          PostUploadMediaItem(
            file: file,
            previewBytes: bytes,
            type: 'image',
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedMediaItems.addAll(pickedItems);
      });

      if (files.length > filesToAdd.length && mounted) {
        _showLimitReachedSnackBar();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('לא ניתן לבחור תמונות כעת'),
          backgroundColor: Colors.redAccent,
        ),
      );
      if (kDebugMode) {
        debugPrint('Gallery image pick failed: $error');
      }
    } finally {
      if (mounted) {
        _initializeCamera();
      }
    }
  }

  Future<void> _pickVideoFromGallery() async {
    if (!_canAddMoreMedia) {
      _showLimitReachedSnackBar();
      return;
    }

    await _disposeCameraController();

    try {
      final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (file == null || !mounted) {
        return;
      }

      final previewBytes = await buildVideoPreviewBytes(file);
      if (!mounted) {
        return;
      }

      setState(() {
        _selectedMediaItems.add(
          PostUploadMediaItem(
            file: file,
            previewBytes: previewBytes,
            type: 'video',
          ),
        );
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('לא ניתן לבחור סרטון כעת'),
          backgroundColor: Colors.redAccent,
        ),
      );
      if (kDebugMode) {
        debugPrint('Gallery video pick failed: $error');
      }
    } finally {
      if (mounted) {
        _initializeCamera();
      }
    }
  }

  Future<void> _showGalleryPicker() async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: isLight ? Colors.white : const Color(0xFF111927),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickImagesFromGallery();
                  },
                  leading: Icon(
                    Icons.photo_library_rounded,
                    color: isLight ? Colors.black : Colors.white,
                  ),
                  title: Text(
                    'הוסף תמונות',
                    style:
                        TextStyle(color: isLight ? Colors.black : Colors.white),
                  ),
                ),
                ListTile(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickVideoFromGallery();
                  },
                  leading: Icon(
                    Icons.video_library_rounded,
                    color: isLight ? Colors.black : Colors.white,
                  ),
                  title: Text(
                    'הוסף סרטון',
                    style:
                        TextStyle(color: isLight ? Colors.black : Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _removeMediaAt(int index) {
    if (index < 0 || index >= _selectedMediaItems.length) {
      return;
    }
    setState(() {
      _selectedMediaItems.removeAt(index);
    });
  }

  void _openDrafts() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const MyProfileScreen(initialCategoryKey: 'drafts'),
      ),
      (route) => false,
    );
  }

  Future<void> _goToDesignScreen() async {
    if (_selectedMediaItems.isEmpty) {
      return;
    }

    _flashEnabled = false;
    _isWhiteScreenFlashActive = false;
    _whiteScreenFlashAlpha = 0;
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
      } catch (_) {
        // Ignore unsupported reset.
      }
    }

    await _disposeCameraController();
    if (!mounted) {
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PostEditScreen(
          selectedMediaItems:
              List<PostUploadMediaItem>.from(_selectedMediaItems),
          initialCategory: widget.initialCategory,
          initialSubCategory: widget.initialSubCategory,
        ),
      ),
    );

    if (mounted) {
      _initializeCamera();
    }
  }

  Future<void> _closeCameraScreen() async {
    _flashEnabled = false;
    _isWhiteScreenFlashActive = false;
    _whiteScreenFlashAlpha = 0;
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
      } catch (_) {
        // Ignore unsupported flash reset.
      }
    }

    if (_selectedMediaItems.isNotEmpty) {
      if (!mounted) {
        return;
      }

      final isLight = Theme.of(context).brightness == Brightness.light;
      final shouldDiscard = await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                backgroundColor:
                    isLight ? Colors.white : const Color(0xFF1E2632),
                title: Text(
                  'לצאת ממסך המצלמה?',
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                content: Text(
                  'כבר צולמה/נבחרה מדיה. ביציאה כעת כל המדיה תימחק. להמשיך?',
                  style: TextStyle(
                    color: isLight ? Colors.black54 : Colors.white70,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF3B30),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('לצאת ולמחוק'),
                  ),
                ],
              );
            },
          ) ??
          false;

      if (!shouldDiscard) {
        return;
      }
    }

    await _disposeCameraController();
    if (!mounted) {
      return;
    }

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Widget _buildCameraPreview() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final controller = _cameraController;
    final canRenderPreview =
        controller != null &&
        controller.value.isInitialized;

    if (!canRenderPreview) {
      if (_cameraError != null &&
          !_isCameraOperationInProgress &&
          !_isSwitchingCamera &&
          !_isTransitioning) {
        return Center(
          child: Text(
            _cameraError!,
            style: TextStyle(
              color: isLight ? Colors.black54 : Colors.white70,
              fontSize: 16,
            ),
            textAlign: TextAlign.center,
          ),
        );
      }

      return const SizedBox.expand(
        child: ColoredBox(color: Colors.black),
      );
    }

    final previewSize = controller.value.previewSize;
    if (previewSize == null || previewSize.width <= 0 || previewSize.height <= 0) {
      // Avoid buildPreview on unstable preview dimensions.
      return CameraPreview(controller);
    }

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: previewSize.height,
            height: previewSize.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraTransitionOverlay() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 90),
      opacity: _isTransitioning ? 1 : 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildMediaStrip() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    if (_selectedMediaItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 96,
      right: 12,
      left: 12,
      child: SizedBox(
        height: 84,
        child: ListView.separated(
          reverse: true,
          scrollDirection: Axis.horizontal,
          itemCount: _selectedMediaItems.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final item = _selectedMediaItems[index];
            return Stack(
              children: [
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    color: isLight
                        ? Colors.white.withValues(alpha:  0.78)
                        : Colors.black.withValues(alpha:  0.58),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: item.previewBytes != null
                        ? Image.memory(
                            item.previewBytes!,
                            fit: BoxFit.cover,
                            width: 74,
                            height: 74,
                          )
                        : (item.isVideo
                            ? _VideoCoverTile(
                                sourcePath: item.file.path,
                                isLight: isLight,
                              )
                            : Container(
                                color: isLight
                                    ? const Color(0xFFEFF5FF)
                                    : const Color(0xFF141925),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.image_not_supported_rounded,
                                  color:
                                      isLight ? Colors.black54 : Colors.white,
                                  size: 24,
                                ),
                              )),
                  ),
                ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: isLight
                          ? Colors.white.withValues(alpha:  0.86)
                          : Colors.black.withValues(alpha:  0.75),
                      shape: BoxShape.circle,
                    ),
                    child: InkWell(
                      onTap: () => _removeMediaAt(index),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: isLight ? Colors.black : Colors.white,
                      ),
                    ),
                  ),
                ),
                if (item.isVideo)
                  const Positioned(
                    bottom: 6,
                    right: 6,
                    child: Icon(
                      Icons.videocam_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildControls() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final hasMedia = _selectedMediaItems.isNotEmpty;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          color: isLight
              ? const Color(0xFFCFEFFF).withValues(alpha:  0.78)
              : Colors.black.withValues(alpha:  0.34),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasMedia)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => _goToDesignScreen(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9E7CFF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        'המשך לעריכת הפוסט (${_selectedMediaItems.length}/$_maxMediaItems)',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _buildBottomIcon(
                            icon: Icons.drafts_rounded,
                            label: 'טיוטות',
                            onTap: _openDrafts,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _buildCaptureButton(isLight),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildBottomIcon(
                            icon: Icons.photo_library_rounded,
                            label: 'גלריה',
                            onTap: _showGalleryPicker,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureButton(bool isLight) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _capturePhoto,
          onLongPressStart: (_) => _startVideoRecording(),
          onLongPressEnd: (_) => _handleVideoRelease(),
          onLongPressUp: _handleVideoRelease,
          onLongPressCancel: _handleVideoRelease,
          child: Listener(
            onPointerUp: (_) => _handleVideoRelease(),
            onPointerCancel: (_) => _handleVideoRelease(),
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF9E7CFF), Color(0xFF53C1F9)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF9E7CFF).withValues(alpha:  0.25),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: _isRecordingVideo ? 30 : 56,
                  height: _isRecordingVideo ? 30 : 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      _isRecordingVideo ? 10 : 999,
                    ),
                    color: _isRecordingVideo
                        ? Colors.redAccent
                        : (isLight ? Colors.white : const Color(0xFF0B1019)),
                    border: Border.all(
                      color: _isRecordingVideo
                          ? (isLight ? Colors.black : Colors.white)
                          : const Color(0xFF9E7CFF),
                      width: 3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'הקש לצילום, לחיצה ארוכה לווידאו',
          style: TextStyle(
            color: isLight ? Colors.black54 : Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildFlashButton(bool isLight) {
    final active = _flashEnabled;
    return InkWell(
      onTap: _toggleFlash,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isLight
              ? Colors.white.withValues(alpha: 0.9)
              : const Color(0xFF172235),
          border: Border.all(
            color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
          ),
        ),
        child: Icon(
          active ? Icons.flash_on_rounded : Icons.flash_off_rounded,
          color: active
              ? const Color(0xFFFFC857)
              : (isLight ? const Color(0xFF4C63A3) : const Color(0xFF9EDBFF)),
        ),
      ),
    );
  }

  Widget _buildCameraFlipButton(bool isLight) {
    return InkWell(
      onTap: _toggleCameraLens,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isLight
              ? Colors.white.withValues(alpha:  0.9)
              : const Color(0xFF172235),
          border: Border.all(
            color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
          ),
        ),
        child: Icon(
          Icons.cameraswitch_rounded,
          color: isLight ? const Color(0xFF4C63A3) : const Color(0xFF9EDBFF),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return PopScope(
      canPop: false,
      child: SwipeBackWrapper(
        enabled: false,
        child: Scaffold(
          backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: isLight
                ? Colors.white.withValues(alpha:  0.6)
                : Colors.black.withValues(alpha:  0.2),
            elevation: 0,
            leading: IconButton(
              icon: Icon(
                Icons.close,
                color: isLight ? Colors.black : Colors.white,
              ),
              onPressed: _closeCameraScreen,
            ),
            actions: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: Center(
                  child: _buildFlashButton(isLight),
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: Center(
                  child: _buildCameraFlipButton(isLight),
                ),
              ),
            ],
            title: const Text(''),
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                  color: isLight ? Colors.white : const Color(0xFF0B1019)),
              Positioned.fill(
                child: GestureDetector(
                  onDoubleTap: _toggleCameraLens,
                  child: _buildCameraPreview(),
                ),
              ),
              if (_isTransitioning)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _buildCameraTransitionOverlay(),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          (isLight ? Colors.white : Colors.black)
                              .withValues(alpha:  0.18),
                          Colors.black.withValues(alpha:  0.0),
                          (isLight ? Colors.white : Colors.black)
                              .withValues(alpha:  0.18),
                        ],
                        stops: const [0.0, 0.4, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              if (_isWhiteScreenFlashActive && _isFrontCamera && _flashEnabled)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      color: Colors.white.withValues(alpha: _whiteScreenFlashAlpha),
                    ),
                  ),
                ),
              _buildMediaStrip(),
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomIcon({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: isLight
              ? Colors.white.withValues(alpha:  0.82)
              : Colors.white.withValues(alpha:  0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isLight ? const Color(0xFFA9C3FF) : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(icon, color: isLight ? Colors.black : Colors.white, size: 22),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  color: isLight ? Colors.black87 : Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoCoverTile extends StatefulWidget {
  final String sourcePath;
  final bool isLight;

  const _VideoCoverTile({
    required this.sourcePath,
    required this.isLight,
  });

  @override
  State<_VideoCoverTile> createState() => _VideoCoverTileState();
}

class _VideoCoverTileState extends State<_VideoCoverTile> {
  VideoPlayerController? _controller;
  Uint8List? _previewBytes;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreviewBytes());
    final source = widget.sourcePath.trim();
    if (source.isEmpty) {
      return;
    }

    final isRemote =
        source.startsWith('http://') || source.startsWith('https://');
    final controller = isRemote
        ? VideoPlayerController.networkUrl(Uri.parse(source))
        : (kIsWeb
            ? VideoPlayerController.networkUrl(Uri.parse(source))
            : VideoPlayerController.file(File(source)));
    _controller = controller;
    controller.initialize().then((_) async {
      if (!mounted) {
        return;
      }
      try {
        await controller.seekTo(const Duration(milliseconds: 600));
      } catch (_) {
        // Keep first frame if seeking is not supported.
      }
      if (!mounted) {
        return;
      }
      setState(() {});
    }).catchError((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _loadPreviewBytes() async {
    final source = widget.sourcePath.trim();
    if (source.isEmpty) {
      return;
    }

    final bytes = await buildVideoPreviewBytesFromSource(source);
    if (!mounted || bytes == null) {
      return;
    }

    setState(() {
      _previewBytes = bytes;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      final previewBytes = _previewBytes;
      return Container(
        color:
            widget.isLight ? const Color(0xFFEFF5FF) : const Color(0xFF141925),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (previewBytes != null)
              Image.memory(
                previewBytes,
                fit: BoxFit.cover,
              ),
            Align(
              alignment: Alignment.center,
              child: Icon(
                Icons.play_circle_fill_rounded,
                color: widget.isLight ? Colors.black54 : Colors.white,
                size: 28,
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ],
    );
  }
}
