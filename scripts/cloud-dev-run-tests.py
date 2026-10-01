#!/usr/bin/env python3
"""Exercise the public Cloud Dev run commands without Apple accounts or devices."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
import signal
import threading
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, plistlib, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['FAKE_CALLS'], 'a') as f:
    f.write(json.dumps([tool, args]) + '\n')
if tool == 'xcodebuild':
    settings = dict(a.split('=', 1) for a in args if '=' in a and not a.startswith('-'))
    target = args[args.index('-target') + 1] if '-target' in args else (
        'SnipSnap' if args[args.index('-scheme') + 1] == 'SnipSnap' else 'SnipSnapiOS')
    mac = target == 'SnipSnap'
    product = settings.get('PRODUCT_BUNDLE_IDENTIFIER', settings.get(
        'SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER' if mac else 'SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER', os.environ.get(
        'SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER' if mac else 'SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER',
        'org.example.snipsnap' if mac else 'org.example.snipsnap.ios')))
    if target == 'SnipSnapShareExtension':
        product = settings.get('SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER', os.environ.get(
            'SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER', product + '.share'))
    group = settings.get('SNIP_SNAP_APP_GROUP_IDENTIFIER', os.environ.get(
        'SNIP_SNAP_APP_GROUP_IDENTIFIER', 'group.org.example.snipsnap'))
    container = 'iCloud.org.example.snipsnap'
    if '-showBuildSettings' in args:
        print(f'Build settings for action build and target {target}:')
        values = {'DEVELOPMENT_TEAM': 'FAKE123456', 'PRODUCT_BUNDLE_IDENTIFIER': product,
            'SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER': 'org.example.snipsnap',
            'SNIP_SNAP_APP_GROUP_IDENTIFIER': group, 'SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER': container,
            'CODE_SIGN_ENTITLEMENTS': 'SnipSnapShareExtension/SnipSnapShareExtension.entitlements'
                if target == 'SnipSnapShareExtension' else os.environ['FAKE_ENTITLEMENTS']}
        for key, value in values.items(): print(f'    {key} = {value}')
    else:
        if os.environ.get('FAKE_BUILD_FAIL'): sys.exit(65)
        root = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products'
        name = settings.get('SNIP_SNAP_PRODUCT_NAME', 'Snip Snap iOS')
        app = root / ('Debug' if mac else 'Debug-iphoneos') / (name + '.app')
        info_dir = app / 'Contents' if mac else app
        info_dir.mkdir(parents=True, exist_ok=True)
        info = {'CFBundleIdentifier': product, 'CFBundleExecutable': name,
            'SnipSnapCloudKitContainerIdentifier': container}
        if mac: info['SnipSnapDevelopmentStorePath'] = settings.get('SNIP_SNAP_DEV_STORE_PATH', '')
        if not mac: info['SnipSnapAppGroupIdentifier'] = group
        (info_dir / 'Info.plist').write_bytes(plistlib.dumps(info))
        ent = {'com.apple.developer.icloud-container-environment': os.environ.get('FAKE_SIGNED_ENV', 'Development'),
            'com.apple.developer.icloud-services': ['CloudKit'],
            'com.apple.developer.icloud-container-identifiers': [container],
            'com.apple.security.application-groups': [group],
            'com.apple.developer.aps-environment' if mac else 'aps-environment': 'development'}
        signed_team = os.environ.get('FAKE_SIGNED_TEAM', 'FAKE123456')
        ent['com.apple.developer.team-identifier'] = signed_team
        ent['com.apple.application-identifier' if mac else 'application-identifier'] = signed_team + '.' + product
        (app / '.signed-entitlements').write_bytes(plistlib.dumps(ent))
        profile = info_dir / ('embedded.provisionprofile' if mac else 'embedded.mobileprovision')
        profile_ent = dict(ent)
        profile_ent['com.apple.application-identifier' if mac else 'application-identifier'] = signed_team + '.' + product
        if os.environ.get('FAKE_PROFILE_DENIES_GROUP'):
            profile_ent['com.apple.security.application-groups'] = ['group.some.other.app']
        profile_ent['com.apple.developer.icloud-container-environment'] = (
            ['Production'] if os.environ.get('FAKE_PROFILE_PRODUCTION_ONLY') else ['Development', 'Production'])
        from datetime import datetime, timezone
        profile_metadata = {'Entitlements': profile_ent,
            'ExpirationDate': datetime(2000 if os.environ.get('FAKE_PROFILE_EXPIRED') else 2099, 1, 1),
            'TeamIdentifier': ['OTHERTEAM' if os.environ.get('FAKE_PROFILE_WRONG_TEAM') else signed_team],
            'ApplicationIdentifierPrefix': [signed_team]}
        profile.write_bytes(plistlib.dumps(profile_metadata))
        if not mac:
            share = app / 'PlugIns/SnipSnapShareExtension.appex'
            share.mkdir(parents=True)
            share_id = settings['SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER']
            (share / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': share_id,
                'SnipSnapAppGroupIdentifier': 'group.other.store' if os.environ.get('FAKE_SHARE_WRONG_GROUP') else group}))
            share_team = os.environ.get('FAKE_SHARE_TEAM', signed_team)
            share_ent = {'com.apple.security.application-groups': [group],
                'com.apple.developer.team-identifier': share_team, 'application-identifier': share_team + '.' + share_id}
            (share / '.signed-entitlements').write_bytes(plistlib.dumps(share_ent))
            share_profile = dict(profile_metadata, Entitlements=share_ent, TeamIdentifier=[share_team], ApplicationIdentifierPrefix=[share_team])
            if os.environ.get('FAKE_SHARE_PROFILE_EXPIRED'): share_profile['ExpirationDate'] = datetime(2000, 1, 1)
            (share / 'embedded.mobileprovision').write_bytes(plistlib.dumps(share_profile))
        if mac and not os.environ.get('FAKE_REAL_ADHOC'):
            import shutil, subprocess
            executable = info_dir / 'MacOS' / name
            executable.parent.mkdir()
            signed_fixture = app.parent / (name + '-fixture-executable')
            shutil.copy('/bin/sleep', signed_fixture)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(signed_fixture)],
                check=True, capture_output=True)
            signed_fixture.rename(executable)
        if os.environ.get('FAKE_REAL_ADHOC'):
            import shutil, subprocess
            signing_entitlements = app.parent / (name + '.entitlements')
            (app / '.signed-entitlements').rename(signing_entitlements)
            executable = info_dir / 'MacOS' / name
            executable.parent.mkdir()
            shutil.copy('/bin/sleep', executable)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--entitlements',
                str(signing_entitlements), str(app)], check=True, capture_output=True)
            # Prove this fixture has valid integrity; only its signing identity is wrong.
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                check=True, capture_output=True)
elif tool == 'codesign' and '-d' in args:
    if '--entitlements' in args:
        sys.stdout.buffer.write((Path(args[-1]) / '.signed-entitlements').read_bytes())
    else:
        share = args[-1].endswith('.appex')
        if os.environ.get('FAKE_ADHOC') or (share and os.environ.get('FAKE_SHARE_ADHOC')):
            print('Signature=adhoc\nTeamIdentifier=not set', file=sys.stderr)
        else:
            team = os.environ.get('FAKE_ACTUAL_TEAM', os.environ.get(
                'FAKE_SHARE_TEAM' if share else 'FAKE_SIGNED_TEAM', 'FAKE123456'))
            authority = 'Apple Distribution' if os.environ.get('FAKE_DISTRIBUTION_SIGNATURE') else 'Apple Development'
            print('Authority=' + authority + ': Fixture\nTeamIdentifier=' + team, file=sys.stderr)
elif tool == 'codesign' and '-R' in args:
    if os.environ.get('FAKE_ADHOC') or (args[-1].endswith('.appex') and os.environ.get('FAKE_SHARE_ADHOC')):
        sys.exit(1)
elif tool == 'ditto':
    if os.environ.get('FAKE_COPY_FAIL'): sys.exit(1)
    import subprocess
    status = subprocess.run(['/usr/bin/ditto', *args]).returncode
    if status == 0 and os.environ.get('FAKE_TAMPER_STAGED_COPY'):
        entitlements = Path(args[-1]) / '.signed-entitlements'
        ent = plistlib.loads(entitlements.read_bytes())
        ent['com.apple.developer.icloud-container-environment'] = 'Production'
        entitlements.write_bytes(plistlib.dumps(ent))
    sys.exit(status)
elif tool == 'security':
    sys.stdout.buffer.write(Path(args[args.index('-i') + 1]).read_bytes())
elif tool == 'open':
    status = int(os.environ.get('FAKE_OPEN_STATUS', '0'))
    if status == 0 and not os.environ.get('FAKE_OPEN_NO_PROCESS'):
        import subprocess
        app = Path(args[-1])
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
        child = subprocess.Popen([str(executable), '100'], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        with open(os.environ['FAKE_PROCESSES'], 'a') as f:
            f.write(json.dumps({'pid': child.pid, 'executable': str(executable)}) + '\n')
    sys.exit(status)
elif tool == 'xcrun' and args[:3] == ['devicectl', 'device', 'install']:
    sys.exit(int(os.environ.get('FAKE_DEVICE_INSTALL_STATUS', '0')))
elif tool == 'xcrun' and args[:4] == ['devicectl', 'device', 'process', 'launch']:
    sys.exit(int(os.environ.get('FAKE_DEVICE_LAUNCH_STATUS', '0')))
'''


class CloudDevRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='snip-snap-cloud-run-')
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('xcodebuild', 'codesign', 'security', 'xcrun', 'open', 'ditto'):
            p = self.bin / name
            p.write_text(FAKE_TOOL)
            p.chmod(0o755)
        ent = self.root / 'Development.entitlements'
        ent.write_bytes(plistlib.dumps({
            'com.apple.developer.icloud-container-environment': 'Development',
            'com.apple.developer.icloud-services': ['CloudKit'],
            'com.apple.developer.icloud-container-identifiers': ['$(SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER)'],
            'com.apple.security.application-groups': ['$(SNIP_SNAP_APP_GROUP_IDENTIFIER)'],
            'com.apple.developer.aps-environment': 'development', 'aps-environment': 'development',
        }))
        self.calls_path = self.root / 'calls.jsonl'
        self.processes_path = self.root / 'processes.jsonl'
        self.addCleanup(self.stop_started_apps)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
            SNIP_SNAP_DEV_STATE_DIR=str(self.root / 'state'), SNIP_SNAP_DEV_SLOT='1',
            SNIP_SNAP_XCODEBUILD=str(self.bin / 'xcodebuild'),
            SNIP_SNAP_CODESIGN=str(self.bin / 'codesign'),
            SNIP_SNAP_SECURITY=str(self.bin / 'security'),
            SNIP_SNAP_DITTO=str(self.bin / 'ditto'), SNIP_SNAP_OPEN=str(self.bin / 'open'), SNIP_SNAP_XCRUN=str(self.bin / 'xcrun'),
            FAKE_ENTITLEMENTS=str(ent), FAKE_CALLS=str(self.calls_path),
            FAKE_PROCESSES=str(self.processes_path))
        for name in ('SNIP_SNAP_DEV_MAC_PRODUCT_BUNDLE_IDENTIFIER', 'SNIP_SNAP_DEV_IOS_PRODUCT_BUNDLE_IDENTIFIER',
                     'SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER', 'SNIP_SNAP_CLOUD_DEV_DERIVED_DATA'):
            self.env.pop(name, None)

    def stop_started_apps(self):
        if not self.processes_path.exists():
            return
        for line in self.processes_path.read_text().splitlines():
            process = json.loads(line)
            current = subprocess.run(['/bin/ps', '-p', str(process['pid']), '-o', 'command='],
                                     capture_output=True, text=True).stdout.strip()
            if current == process['executable'] + ' 100':
                try:
                    os.kill(process['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def run_command(self, *args, **extra):
        return subprocess.run([str(SCRIPTS / 'run.sh'), *args], env={**self.env, **extra},
                              capture_output=True, text=True, timeout=90)

    def calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()] if self.calls_path.exists() else []

    def test_mac_run_uses_cloud_slot_and_installs_before_opening(self):
        r = self.run_command('cloud-mac')
        self.assertEqual(r.returncode, 0, r.stderr)
        opens = [args for tool, args in self.calls() if tool == 'open']
        self.assertEqual(len(opens), 1)
        installed = self.root / 'state/apps/cloud-slot-1/SnipSnapCloudDev1.app'
        self.assertIn(str(installed), opens[0])
        self.assertTrue(installed.is_dir())
        info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'org.example.snipsnap.cloud.dev1')
        self.assertEqual(info['SnipSnapDevelopmentStorePath'], f'{self.root}/state/data/cloud-slot-1/items.json')
        self.assertIn(f'SNIP_SNAP_STORE_PATH={self.root}/state/data/cloud-slot-1/items.json', opens[0])

    def test_maximum_slot_stops_only_its_existing_app_before_relaunch(self):
        executable = self.root / 'state/apps/cloud-slot-1000/SnipSnapCloudDev1000.app/Contents/MacOS/SnipSnapCloudDev1000'
        executable.parent.mkdir(parents=True)
        shutil.copy('/bin/sleep', executable)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(executable)],
                       check=True, capture_output=True)
        child = subprocess.Popen([str(executable), '100'])
        self.addCleanup(lambda: child.poll() is not None or child.terminate())
        waiter = threading.Thread(target=child.wait, daemon=True)
        waiter.start()
        waiter.join(timeout=0.3)
        self.assertIsNone(child.poll(), 'The stop fixture must be running before the runner starts')
        r = self.run_command('cloud-mac', SNIP_SNAP_DEV_SLOT='1000')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNotNone(child.poll(), 'Previous slot process must stop before opening its replacement')

    def test_failed_copy_keeps_previous_installed_app(self):
        marker = self.root / 'state/apps/cloud-slot-1/SnipSnapCloudDev1.app/previous-valid-build'
        marker.parent.mkdir(parents=True)
        marker.write_text('valid previous build')
        r = self.run_command('cloud-mac', FAKE_COPY_FAIL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(marker.exists(), 'Failed replacement must preserve previous installation')
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_failed_mac_launch_keeps_previous_backup(self):
        installed_root = self.root / 'state/apps/cloud-slot-1'
        previous = installed_root / 'SnipSnapCloudDev1.app/previous-valid-build'
        previous.parent.mkdir(parents=True)
        previous.write_text('valid previous build')

        r = self.run_command('cloud-mac', FAKE_OPEN_STATUS='77')

        self.assertEqual(r.returncode, 77, r.stderr)
        backups = list(installed_root.glob('.cloud-install.*/previous.app/previous-valid-build'))
        self.assertEqual(len(backups), 1, 'Failed launch must preserve the previous executable')
        self.assertEqual(backups[0].read_text(), 'valid previous build')
        self.assertIn(str(backups[0].parent), r.stderr)
        self.assertFalse((self.root / 'state/locks/cloud-macos-slot-1').exists())

    def test_accepted_mac_launch_without_process_keeps_previous_backup(self):
        installed_root = self.root / 'state/apps/cloud-slot-1'
        previous = installed_root / 'SnipSnapCloudDev1.app/previous-valid-build'
        previous.parent.mkdir(parents=True)
        previous.write_text('valid previous build')
        r = self.run_command('cloud-mac', FAKE_OPEN_NO_PROCESS='1')
        self.assertNotEqual(r.returncode, 0, 'Accepted launch must not claim a missing process is running')
        self.assertIn('did not stay open', r.stderr)
        self.assertNotIn('Opened Snip Snap', r.stdout)
        backups = list(installed_root.glob('.cloud-install.*/previous.app/previous-valid-build'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'valid previous build')
        self.assertIn(str(backups[0].parent), r.stderr)
        self.assertFalse((self.root / 'state/locks/cloud-macos-slot-1').exists())

    def test_failed_phone_install_or_launch_keeps_previous_backup(self):
        for operation, status in (('INSTALL', 78), ('LAUNCH', 79)):
            with self.subTest(operation=operation):
                installed_root = self.root / ('phone-' + operation) / 'apps/cloud-slot-1'
                previous = installed_root / 'Snip Snap iOS.app/previous-valid-build'
                previous.parent.mkdir(parents=True)
                previous.write_text('valid previous build')
                r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', **{
                    'SNIP_SNAP_DEV_STATE_DIR': str(installed_root.parent.parent),
                    'FAKE_DEVICE_' + operation + '_STATUS': str(status),
                })
                self.assertEqual(r.returncode, status, r.stderr)
                backups = list(installed_root.glob('.cloud-install.*/previous.app/previous-valid-build'))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_text(), 'valid previous build')
                self.assertIn(str(backups[0].parent), r.stderr)
                self.assertFalse((installed_root.parent.parent / 'locks/cloud-ios-slot-1').exists())

    def test_tampered_staged_copy_never_replaces_or_opens(self):
        previous = self.root / 'state/apps/cloud-slot-1/SnipSnapCloudDev1.app/previous-valid-build'
        previous.parent.mkdir(parents=True)
        previous.write_text('valid previous build')
        r = self.run_command('cloud-mac', FAKE_TAMPER_STAGED_COPY='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Development', r.stderr)
        self.assertEqual(previous.read_text(), 'valid previous build')
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_ios_run_installs_separate_cloud_identity(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE')
        self.assertEqual(r.returncode, 0, r.stderr)
        device_calls = [args for tool, args in self.calls() if tool == 'xcrun' and args[:1] == ['devicectl']]
        self.assertEqual(len(device_calls), 2)
        self.assertEqual(device_calls[0][:4], ['devicectl', 'device', 'install', 'app'])
        self.assertIn('FAKE-DEVICE', device_calls[0])
        self.assertEqual(device_calls[1][-1], 'org.example.snipsnap.ios.cloud.dev1')
        builds = [args for tool, args in self.calls() if tool == 'xcodebuild' and 'build' in args]
        self.assertIn('SNIP_SNAP_APP_GROUP_IDENTIFIER=group.org.example.snipsnap.cloud.dev1', builds[0])
        self.assertIn('SNIP_SNAP_DISPLAY_NAME=Snip Snap Cloud Dev 1', builds[0])

    def test_production_signed_app_never_installs_or_opens(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', FAKE_SIGNED_ENV='Production')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Development', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_adhoc_signature_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_ADHOC='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_real_adhoc_signature_with_matching_entitlements_never_opens(self):
        r = self.run_command('cloud-mac', FAKE_REAL_ADHOC='1',
                             SNIP_SNAP_CODESIGN='/usr/bin/codesign')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('valid Apple-issued signature', r.stderr)
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_actual_signature_team_must_match_configured_team(self):
        r = self.run_command('cloud-mac', FAKE_ACTUAL_TEAM='OTHERTEAM')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('configured signing team', r.stderr)
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_distribution_signature_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_DISTRIBUTION_SIGNATURE='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_share_adhoc_signature_never_installs_or_opens(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', FAKE_SHARE_ADHOC='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'xcrun' and args[:1] == ['devicectl'] for tool, args in self.calls()))

    def test_failed_build_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_BUILD_FAIL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))
        self.assertFalse((self.root / 'state/locks/cloud-macos-slot-1').exists())

    def test_profile_without_dev_group_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_PROFILE_DENIES_GROUP='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('provisioning profile', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))
        self.assertFalse((self.root / 'state/locks/cloud-macos-slot-1').exists())

    def test_mac_team_owned_group_needs_no_profile_group_grant(self):
        r = self.run_command('cloud-mac', FAKE_PROFILE_DENIES_GROUP='1',
            SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER='FAKE123456.org.example.snipsnap.cloud.dev1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([1 for tool, _ in self.calls() if tool == 'open']), 1)

    def test_mac_group_owned_by_another_team_never_opens(self):
        r = self.run_command('cloud-mac',
            SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER='OTHERTEAM.org.example.snipsnap.cloud.dev1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'open' for tool, _ in self.calls()))

    def test_ios_rejects_mac_only_team_group_even_with_profile_grant(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE',
            SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER='FAKE123456.org.example.snipsnap.cloud.dev1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'xcrun' and args[:1] == ['devicectl'] for tool, args in self.calls()))

    def test_device_id_is_required_before_claiming_or_building(self):
        r = self.run_command('cloud-ios-device')
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.calls())
        self.assertFalse((self.root / 'state').exists())

    def test_production_only_profile_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_PROFILE_PRODUCTION_ONLY='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Development environment', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_run_rejects_production_identity(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE',
                             SNIP_SNAP_DEV_IOS_PRODUCT_BUNDLE_IDENTIFIER='org.example.snipsnap.ios')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_custom_cloud_identity_cannot_replace_ordinary_device_dev_app(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE',
            SNIP_SNAP_DEV_IOS_PRODUCT_BUNDLE_IDENTIFIER='world.sree.snipsnap.ios.dev1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_expired_profile_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_PROFILE_EXPIRED='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('unexpired', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_mismatched_profile_team_never_installs_or_opens(self):
        r = self.run_command('cloud-mac', FAKE_PROFILE_WRONG_TEAM='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('team', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_consistently_wrong_signing_team_never_installs_or_opens(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', FAKE_SIGNED_TEAM='OTHERTEAM')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('configured signing team', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_share_team_must_match_configured_main_team(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', FAKE_SHARE_TEAM='OTHERTEAM')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('configured signing team', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_share_store_group_mismatch_never_installs_or_opens(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', FAKE_SHARE_WRONG_GROUP='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Share extension configured App Group', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))

    def test_expired_share_profile_never_installs_or_opens(self):
        r = self.run_command('cloud-ios-device', 'FAKE-DEVICE', FAKE_SHARE_PROFILE_EXPIRED='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('unexpired', r.stderr)
        self.assertFalse(any(tool == 'open' or (tool == 'xcrun' and args[:1] == ['devicectl']) for tool, args in self.calls()))


if __name__ == '__main__':
    unittest.main()
