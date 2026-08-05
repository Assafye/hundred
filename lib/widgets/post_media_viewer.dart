import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/post_media_item.dart';

class PostMediaViewer extends StatefulWidget {
  final List<PostMediaItem> mediaItems;
  final double? aspectRatio;
  final BorderRadius? borderRadius;
  final bool showIndicators;
  final bool showDesktopNavigationArrows;
  final bool isActive;

  const PostMediaViewer({
    super.key,
    required this.mediaItems,
    this.aspectRatio = 16 / 9,
    this.borderRadius,
    this.showIndicators = true,
    this.showDesktopNavigationArrows = false,
    this.isActive = true,
  });

  @override
  State<PostMediaViewer> createState() => _PostMediaViewerState();
}

class _PostMediaViewerState extends State<PostMediaViewer> {
  late final PageController _pageController;
  int _currentIndex = 0;
  final Map<String, Future<String?>> _resolvedMediaUrlByRawUrl =
      <String, Future<String?>>{};

  bool _isHttpUrl(String url) {
    final normalized = url.trim().toLowerCase();
    return normalized.startsWith('http://') ||
        normalized.startsWith('https://');
  }

  Future<String?> _resolveStorageMediaUrl(String rawUrl) async {
    final normalized = rawUrl.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (_isHttpUrl(normalized)) {
      return normalized;
    }

    try {
      if (normalized.startsWith('gs://')) {
        return await FirebaseStorage.instance
            .refFromURL(normalized)
            .getDownloadURL();
      }
      return await FirebaseStorage.instance.ref(normalized).getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolvedMediaUrlFuture(String rawUrl) {
    return _resolvedMediaUrlByRawUrl.putIfAbsent(
      rawUrl,
      () => _resolveStorageMediaUrl(rawUrl),
    );
  }

  Widget _imageErrorWidget() {
    return Container(
      color: const Color(0xFF1A2230),
      alignment: Alignment.center,
      child: const Icon(
        Icons.broken_image_outlined,
        color: Colors.white38,
        size: 34,
      ),
    );
  }

  Widget _buildNetworkImage(PostMediaItem item, String imageUrl) {
    return Transform.scale(
      scale: item.cropScale,
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        fit: BoxFit.cover,
        alignment: Alignment(item.cropAlignmentX, item.cropAlignmentY),
        progressIndicatorBuilder: (context, url, progress) {
          return Container(
            color: const Color(0xFF1A2230),
            alignment: Alignment.center,
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                value: progress.progress,
                strokeWidth: 2.4,
                color: Colors.white70,
              ),
            ),
          );
        },
        errorWidget: (context, url, error) => _imageErrorWidget(),
      ),
    );
  }

  Future<void> _goToPage(int index) async {
    if (!_pageController.hasClients) {
      return;
    }
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaItems.isEmpty) {
      if (widget.aspectRatio == null) {
        return Container(color: const Color(0xFF1A2230));
      }
      return AspectRatio(
        aspectRatio: widget.aspectRatio!,
        child: Container(color: const Color(0xFF1A2230)),
      );
    }

    final stackBody = Stack(
      children: [
        Positioned.fill(
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.mediaItems.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              final item = widget.mediaItems[index];
              if (item.isVideo) {
                return _InlineVideoPlayer(
                  url: item.url,
                  isActive: widget.isActive,
                );
              }
              final rawUrl = item.url.trim();
              if (rawUrl.isEmpty) {
                return _imageErrorWidget();
              }

              if (_isHttpUrl(rawUrl)) {
                return _buildNetworkImage(item, rawUrl);
              }

              return FutureBuilder<String?>(
                future: _resolvedMediaUrlFuture(rawUrl),
                builder: (context, snapshot) {
                  final resolvedUrl = (snapshot.data ?? '').trim();
                  if (resolvedUrl.isEmpty) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Container(
                        color: const Color(0xFF1A2230),
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white70,
                          ),
                        ),
                      );
                    }
                    return _imageErrorWidget();
                  }
                  return _buildNetworkImage(item, resolvedUrl);
                },
              );
            },
          ),
        ),
        if (widget.showDesktopNavigationArrows &&
            widget.mediaItems.length > 1)
          Positioned(
            left: 12,
            right: 12,
            top: 0,
            bottom: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _MediaNavArrow(
                  icon: Icons.chevron_right_rounded,
                  onPressed: _currentIndex > 0
                      ? () => _goToPage(_currentIndex - 1)
                      : null,
                ),
                _MediaNavArrow(
                  icon: Icons.chevron_left_rounded,
                  onPressed: _currentIndex < widget.mediaItems.length - 1
                      ? () => _goToPage(_currentIndex + 1)
                      : null,
                ),
              ],
            ),
          ),
        if (widget.showIndicators && widget.mediaItems.length > 1)
          Positioned(
            bottom: 10,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                widget.mediaItems.length,
                (index) {
                  final isActive = index == _currentIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    width: isActive ? 20 : 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: isActive
                          ? Colors.white
                          : Colors.white.withOpacity( 0.38),
                      boxShadow: isActive
                          ? const [
                              BoxShadow(
                                color: Color(0x8FFFFFFF),
                                blurRadius: 8,
                                offset: Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );

    final body = widget.aspectRatio == null
        ? stackBody
        : AspectRatio(
            aspectRatio: widget.aspectRatio!,
            child: stackBody,
          );

    if (widget.borderRadius == null) {
      return body;
    }

    return ClipRRect(
      borderRadius: widget.borderRadius!,
      child: body,
    );
  }
}

class _MediaNavArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _MediaNavArrow({
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: onPressed == null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: onPressed == null ? 0.25 : 1,
        child: Material(
          color: Colors.black.withOpacity( 0.36),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 34,
              height: 34,
              child: Icon(
                icon,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineVideoPlayer extends StatefulWidget {
  final String url;
  final bool isActive;

  const _InlineVideoPlayer({
    required this.url,
    required this.isActive,
  });

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isPausedByUser = false;
  Offset? _pointerDownLocal;
  DateTime? _pointerDownAt;
  bool _pointerMovedTooMuch = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(true)
      ..initialize().then((_) {
        if (!mounted) {
          return;
        }
        unawaited(_applyPlaybackState());
        setState(() {});
      });
  }

  @override
  void didUpdateWidget(covariant _InlineVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.isActive != widget.isActive) {
      unawaited(_applyPlaybackState());
    }
  }

  Future<void> _applyPlaybackState() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      if (widget.isActive) {
        await controller.setVolume(1);
        if (_isPausedByUser) {
          if (controller.value.isPlaying) {
            await controller.pause();
          }
        } else if (!controller.value.isPlaying) {
          await controller.play();
        }
      } else {
        if (controller.value.isPlaying) {
          await controller.pause();
        }
        await controller.setVolume(0);
      }
    } catch (_) {
      // Keep the current playback if media APIs fail on a specific platform.
    }
  }

  Future<void> _togglePlayPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (!widget.isActive) {
      return;
    }

    try {
      if (controller.value.isPlaying) {
        _isPausedByUser = true;
        await controller.pause();
      } else {
        _isPausedByUser = false;
        await controller.setVolume(1);
        await controller.play();
      }
      if (!mounted) {
        return;
      }
      setState(() {});
    } catch (_) {
      // Keep playback state if changing volume fails.
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerDownLocal = event.localPosition;
    _pointerDownAt = DateTime.now();
    _pointerMovedTooMuch = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final start = _pointerDownLocal;
    if (start == null || _pointerMovedTooMuch) {
      return;
    }

    if ((event.localPosition - start).distance > 14) {
      _pointerMovedTooMuch = true;
    }
  }

  Future<void> _handlePointerUp(PointerUpEvent event) async {
    final start = _pointerDownLocal;
    final startedAt = _pointerDownAt;
    _pointerDownLocal = null;
    _pointerDownAt = null;

    if (start == null || startedAt == null || _pointerMovedTooMuch) {
      return;
    }

    final tapDuration = DateTime.now().difference(startedAt);
    if (tapDuration > const Duration(milliseconds: 280)) {
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }

    final center = box.size.center(Offset.zero);
    const centerTapRadius = 120.0;
    if ((event.localPosition - center).distance > centerTapRadius) {
      return;
    }

    await _togglePlayPause();
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
      return Container(
        color: const Color(0xFF121926),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: Colors.white70),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: (event) {
            unawaited(_handlePointerUp(event));
          },
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      ],
    );
  }
}
