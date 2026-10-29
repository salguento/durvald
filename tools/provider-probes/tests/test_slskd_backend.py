import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from slskd_backend import checked_members,configure


class BackendSetupTests(unittest.TestCase):
    def test_configuration_is_private_loopback_only_and_does_not_share_library(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'backend'
            configure(state,new_account=True)
            config=json.loads((state/'slskd.yml').read_text())
            self.assertEqual(config['web']['ip_address'],'127.0.0.1')
            self.assertFalse(config['web']['authentication']['disabled'])
            self.assertEqual(config['web']['authentication']['api_keys']['durvald_validation']['cidr'],'127.0.0.1/32')
            self.assertEqual(config['web']['authentication']['api_keys']['durvald_validation']['role'],'Administrator')
            self.assertFalse(config['remote_configuration'])
            self.assertEqual(config['shares']['directories'],[])
            self.assertFalse(config['flags']['no_connect'])
            self.assertEqual(stat.S_IMODE(state.stat().st_mode),0o700)
            for name in ['credentials.json','slskd.yml']:
                self.assertEqual(stat.S_IMODE((state/name).stat().st_mode),0o600)
            self.assertTrue(Path(config['directories']['downloads']).is_relative_to(state.resolve()))

    def test_reconfiguration_preserves_test_account_and_api_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)
            first=configure(state,new_account=True)
            second=configure(state,new_account=True)
            self.assertEqual(first,second)
            self.assertEqual(first,configure(state))

    def test_backend_without_account_does_not_attempt_automatic_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)
            values=configure(state)
            config=json.loads((state/'slskd.yml').read_text())
            self.assertNotIn('soulseek_username',values)
            self.assertTrue(config['flags']['no_connect'])

    def test_release_archive_rejects_traversal_absolute_paths_and_symlinks(self):
        for path,mode in [('../escape',0o100644),('/absolute',0o100644),('link',stat.S_IFLNK|0o777),('..\\escape',0o100644)]:
            with self.subTest(path=path):
                data=io.BytesIO()
                with zipfile.ZipFile(data,'w') as z:
                    info=zipfile.ZipInfo(path);info.external_attr=mode<<16;z.writestr(info,b'x')
                data.seek(0)
                with zipfile.ZipFile(data) as z,self.assertRaises(ValueError):checked_members(z)

    def test_release_archive_accepts_regular_nested_runtime_files(self):
        data=io.BytesIO()
        with zipfile.ZipFile(data,'w') as z:z.writestr('release/slskd',b'binary')
        data.seek(0)
        with zipfile.ZipFile(data) as z:checked_members(z)

    def test_custom_server_survives_reconfiguration_without_rotating_account(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)
            first=configure(state,new_account=True,server_address='server.slsknet.org',server_port=2242)
            second=configure(state)
            self.assertEqual(first,second)
            config=json.loads((state/'slskd.yml').read_text())
            self.assertEqual(config['soulseek']['address'],'server.slsknet.org')
            self.assertEqual(config['soulseek']['port'],2242)

    def test_stop_refuses_pid_that_belongs_to_another_process(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        from slskd_backend import private_json,stop
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)
            private_json(state/'process.json',{'pid':12345,'binary':'/expected/slskd'})
            with patch('slskd_backend.subprocess.run',return_value=SimpleNamespace(stdout='/another/process')),patch('slskd_backend.os.kill') as kill:
                with self.assertRaises(ValueError):stop(state)
                kill.assert_not_called()

class BackendVerificationTests(unittest.TestCase):
    def fixture(self, state):
        import hashlib
        from slskd_backend import VERSION, ASSET, SHA256, private_json
        binary = state/'release'/'slskd'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'fixture; never executed')
        binary.chmod(0o700)
        manifest = dict(version=VERSION,asset=ASSET,asset_sha256=SHA256,binary='release/slskd',binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        private_json(state/'installation.json',manifest)
        return binary,manifest

    def test_missing_incompatible_modified_and_nonexecutable_installations_fail_closed(self):
        from slskd_backend import verified_installation, private_json
        for case in ['missing','version','asset','checksum','modified','nonexecutable','traversal','absolute','symlink']:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                state=Path(temporary); binary,manifest=self.fixture(state)
                if case=='missing': binary.unlink()
                elif case=='version': manifest['version']='99.0'
                elif case=='asset': manifest['asset']='unverified.zip'
                elif case=='checksum': manifest['asset_sha256']='untrusted'
                elif case=='modified': binary.write_bytes(b'changed')
                elif case=='nonexecutable': binary.chmod(0o600)
                elif case=='traversal': manifest['binary']='release/../other'
                elif case=='absolute': manifest['binary']=str(binary)
                elif case=='symlink':
                    outside=state/'outside'; binary.rename(outside); binary.symlink_to(outside)
                private_json(state/'installation.json',manifest)
                with self.assertRaises((ValueError,OSError)): verified_installation(state)

    def test_existing_verified_installation_is_reused_without_download(self):
        from unittest.mock import patch
        from slskd_backend import install, verified_installation
        with tempfile.TemporaryDirectory() as temporary:
            state=Path(temporary); binary,_=self.fixture(state)
            with patch('slskd_backend.urllib.request.urlopen',side_effect=AssertionError('must stay offline')), patch('slskd_backend.platform.system',return_value='Darwin'), patch('slskd_backend.platform.machine',return_value='arm64'):
                self.assertEqual(verified_installation(state),binary)
                self.assertEqual(install(state),binary)

    def test_failed_readiness_stops_only_spawned_process_and_keeps_credentials(self):
        from unittest.mock import Mock, patch
        from slskd_backend import start
        with tempfile.TemporaryDirectory() as temporary:
            state=Path(temporary); binary,_=self.fixture(state)
            process=Mock(pid=12345); process.poll.return_value=None
            with patch('slskd_backend.owned_pid',return_value=None), patch('slskd_backend.install',return_value=binary), patch('slskd_backend.subprocess.Popen',return_value=process), patch('slskd_backend.status',return_value={'api_authenticated':False}), patch('slskd_backend.time.sleep'), patch('slskd_backend.socket.socket'):
                with self.assertRaises(ValueError): start(state)
            process.terminate.assert_called_once(); process.wait.assert_called_once_with(timeout=10)
            self.assertFalse((state/'process.json').exists())
            self.assertTrue((state/'credentials.json').exists())

    def test_failed_process_record_write_also_stops_spawned_process(self):
        from unittest.mock import Mock, patch
        from slskd_backend import start, configure
        with tempfile.TemporaryDirectory() as temporary:
            state=Path(temporary); binary,_=self.fixture(state); values=configure(state)
            process=Mock(pid=12345); process.poll.return_value=None
            with patch('slskd_backend.configure',return_value=values), patch('slskd_backend.owned_pid',return_value=None), patch('slskd_backend.install',return_value=binary), patch('slskd_backend.subprocess.Popen',return_value=process), patch('slskd_backend.private_json',side_effect=OSError('disk full')), patch('slskd_backend.socket.socket'):
                with self.assertRaises(OSError): start(state)
            process.terminate.assert_called_once(); process.wait.assert_called_once_with(timeout=10)
            self.assertTrue((state/'credentials.json').exists())
