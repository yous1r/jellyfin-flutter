import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jellfin_flutter/core/models/models.dart';

Map<String, dynamic> loadFixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('Views fixture 解析为媒体库列表', () {
    final data = loadFixture('views.json');
    final views = ((data['Items'] as List))
        .whereType<Map<String, dynamic>>()
        .map(LibraryView.fromJson)
        .toList();

    expect(views, isNotEmpty);
    expect(views.first.id, isNotEmpty);
    expect(views.first.name, isNotEmpty);
  });

  test('Resume fixture 解析为分页条目并带播放进度', () {
    final page = ItemsPage.fromJson(loadFixture('resume.json'));

    expect(page.items, isNotEmpty);
    final item = page.items.first;
    expect(item.id, isNotEmpty);
    expect(item.type, isNotEmpty);
    // 继续观看的条目必须有播放位置，否则无法断点续播
    expect(item.userData.playbackPositionTicks, greaterThan(0));
  });

  test('Items 分页 fixture 解析总数与条目', () {
    final page = ItemsPage.fromJson(loadFixture('items_page.json'));

    expect(page.items.length, greaterThan(0));
    expect(page.totalRecordCount, greaterThanOrEqualTo(page.items.length));
  });

  test('PlaybackInfo fixture 解析出可播放 URL', () {
    final result = PlaybackInfoResult.fromJson(loadFixture('playback_info.json'));

    expect(result.playSessionId, isNotEmpty);
    expect(result.mediaSources, isNotEmpty);
    expect(result.mediaSources.first.playUrl, startsWith('http'));
  });

  test('缺省字段安全解析（空对象不抛异常）', () {
    final item = BaseItem.fromJson(const {'Id': 'x', 'Name': 'n', 'Type': 'Movie'});

    expect(item.userData.played, isFalse);
    expect(item.mediaSources, isEmpty);
    expect(item.primaryImageAspectRatio, 0);
  });
}
