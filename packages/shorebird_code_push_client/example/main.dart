import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

Future<void> main() async {
  final client = CodePushClient();

  // List all apps.
  final apps = await client.getApps();

  // Get the list of organization memberships for the current user.
  final memberships = await client.getOrganizationMemberships();

  // Create a new Shorebird application.
  final app = await client.createApp(
    displayName: '<DISPLAY NAME>', // e.g. 'Shorebird Example'
    organizationId: memberships.first.organization.id,
  );

  // Create a channel.
  final channel = await client.createChannel(
    appId: app.id,
    channel: '<CHANNEL>', // e.g. 'stable'
  );

  // Create a release.
  final release = await client.createRelease(
    appId: app.id,
    version: '<VERSION>', // e.g. '1.0.0'
    flutterRevision:
        '<FLUTTER_REVISION>', // e.g. 83305b5088e6fe327fb3334a73ff190828d85713,
    displayName: '<DISPLAY NAME>', // e.g. 'v1.0.0'
  );

  // Create a release artifact.
  await client.createReleaseArtifact(
    appId: app.id,
    releaseId: release.id,
    platform: ReleasePlatform.android,
    artifactPath: '<PATH TO ARTIFACT>', // e.g. 'libapp.so'
    arch: '<ARCHITECTURE>', // e.g. 'aarch64'
    hash: '<HASH>', // 'sha256 hash of the artifact'
    canSideload: true,
    podfileLockHash: '<HASH>', // 'sha256 hash of ios/Podfile.lock'
  );

  // Create a new patch.
  final patch = await client.createPatch(
    appId: app.id,
    releaseId: release.id,
    metadata: {
      'releasePlatform': 'android',
      'usedIgnoreAssetChangesFlag': false,
    },
  );

  // Create a patch artifact.
  await client.createPatchArtifact(
    appId: app.id,
    patchId: patch.id,
    platform: ReleasePlatform.android,
    artifactPath: '<PATH TO ARTIFACT>', // e.g. 'libapp.so'
    arch: '<ARCHITECTURE>', // e.g. 'aarch64'
    hash: '<HASH>', // 'sha256 hash of the artifact'
  );

  // Promote a patch to a channel.
  await client.promotePatch(
    appId: app.id,
    patchId: patch.id,
    channelId: channel.id,
  );

  // Close the client.
  client.close();
}
