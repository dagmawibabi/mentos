import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/plugins/plugins.dart';
import 'support/fake_net.dart';

void main() {
 test('site plugins install, run, persist and cancel safely', () async {
  final root = await Directory.systemTemp.createTemp('site-plugins-');
  final engine = await openEngine(root, TestNetwork());
  final host = PluginHost(engine);
  try {
   for (final id in ['checklist','focus','quick-replies']) {
    final base = '../../site/mentossite/plugins/$id';
    host.install(PluginManifest.parse(jsonDecode(File('$base/plugin.json').readAsStringSync())),File('$base/main.js').readAsStringSync(),origin:'dev');
    expect(host.errorOf(id),isNull,reason:id);
    expect(host.isRunning(id),true,reason:id);
    expect(host.render(host.page(id,'main')!),isA<List>(),reason:id);
   }
   expect(host.runCommand('/todo Test the native runtime','dm:x'),'');
   final page=host.page('checklist','main')!;
   Map listNode() => (host.render(page) as List).whereType<Map>().firstWhere((n)=>n['type']=='list');
   expect((listNode()['items'] as List).first['title'],'○ Test the native runtime');
   host.callback('checklist',(listNode()['items'] as List).first['onTap'],[]);
   expect((listNode()['items'] as List).first['title'],'✓ Test the native runtime');
   expect(host.runCommand('/reply 1','dm:x'),'On my way.');
   expect(host.runCommand('/reply 0','dm:x'),'');
   expect(host.runCommand('/reply invalid','dm:x'),'');
   final replies=host.render(host.page('quick-replies','main')!) as List;
   final input=replies.whereType<Map>().firstWhere((n)=>n['type']=='input');
   host.callback('quick-replies',input['onChange'],['Custom reply']);
   expect(host.runCommand('/reply 1','dm:x'),'Custom reply');
   final focus=host.page('focus','main')!;
   final buttons=(host.render(focus) as List).whereType<Map>().where((n)=>n['type']=='button').toList();
   host.callback('focus',buttons.first['onTap'],[]);
   expect((host.render(focus) as List).first['value'],'25');
   host.callback('focus',buttons.last['onTap'],[]);
   expect((host.render(focus) as List).first['value'],'Ready');
   host.dispose();
   final again=PluginHost(engine);
   expect(again.runCommand('/reply 1','dm:x'),'Custom reply');
   expect(((again.render(again.page('checklist','main')!) as List).whereType<Map>().firstWhere((n)=>n['type']=='list')['items'] as List).first['title'],'✓ Test the native runtime');
   again.setEnabled('focus',false);
   expect(again.isRunning('focus'),false);
   again.dispose();
  } finally {
   host.dispose();
   await engine.stop(); engine.db.close(); await root.delete(recursive:true);
  }
 });
}
