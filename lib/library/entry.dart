import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:video_player_app/core/models.dart';
import 'package:video_player_app/core/slide_snackbar.dart';
import 'package:video_player_app/library/library.dart';
import 'package:video_player_app/main.dart' show library;
import 'package:video_player_app/native/android_bridge.dart';

/// What a row in the Folders list is. Every per-kind difference (labels, icon,
/// what a tap does) lives here and in [Entry], not in the list widgets.
enum EntryKind { folder, video, other }

extension EntryKindInfo on EntryKind {
  String get label => switch (this) {
        EntryKind.folder => 'Folder',
        EntryKind.video => 'Video',
        EntryKind.other => 'File',
      };

  String get openLabel => switch (this) {
        EntryKind.folder => 'Open',
        EntryKind.video => 'Play',
        EntryKind.other => 'Open with another app',
      };
}

/// One file-system row (folder, video or any other file) described in one place.
class Entry {
  Entry(this.fs, {required this.parent});

  final FileSystemEntity fs;
  final String parent;

  String get path => fs.path;
  String get name => p.basename(path);

  late final EntryKind kind = fs is Directory
      ? EntryKind.folder
      : looksLikeVideo(path)
          ? EntryKind.video
          : EntryKind.other;

  bool get isFolder => kind == EntryKind.folder;

  late final int size = fs is File && (fs as File).existsSync() ? (fs as File).lengthSync() : 0;

  /// Every file (video or not) is exposed as a [VideoItem] so selection, copy,
  /// cut, share and delete treat all files the same way. Null for folders.
  late final VideoItem? item = isFolder ? null : _toItem();

  VideoItem _toItem() {
    for (final v in library.videos) {
      if (v.path == path) return v;
    }
    return VideoItem(
      id: path,
      path: path,
      title: name,
      folder: parent,
      size: size,
      modified: fs.statSync().modified,
    );
  }

  /// Key used in the selection set: the folder path, or the item id.
  String get selectionId => item?.id ?? path;

  String get subtitle => switch (kind) {
        EntryKind.folder => 'Folder',
        EntryKind.video => formatBytes(size),
        EntryKind.other => '${formatBytes(size)} · Unsupported file',
      };
}

/// Opens any file in another app (chooser). Shows a message if none can.
Future<void> openInOtherApp(BuildContext context, String path) async {
  final ok = await AndroidBridge.openWithOtherApp(path);
  if (!ok && context.mounted) {
    SlideSnackBar.show(
      context,
      message: 'No app found to open this file',
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    );
  }
}
