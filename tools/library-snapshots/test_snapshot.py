import sqlite3
import tempfile
import unittest
from pathlib import Path
from snapshot import snapshot, path_key


class SnapshotTests(unittest.TestCase):
    def test_export_and_restore_include_committed_wal_schema_and_duplicate_positions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / 'biblioteca #1.sqlite'
            with sqlite3.connect(library) as conn:
                conn.create_function('durvald_local_path_key', 1, path_key, deterministic=True)
                conn.executescript('''
                    PRAGMA journal_mode=WAL;
                    PRAGMA wal_autocheckpoint=0;
                    CREATE TABLE songs(song_id INTEGER PRIMARY KEY, rating INTEGER, favorite INTEGER);
                    CREATE TABLE track_sources(source_id INTEGER PRIMARY KEY, song_id INTEGER REFERENCES songs(song_id), local_path TEXT CHECK(local_path=durvald_local_path_key(local_path)));
                    CREATE TABLE playlist_songs(position INTEGER PRIMARY KEY, song_id INTEGER REFERENCES songs(song_id));
                    CREATE TABLE play_history(history_id INTEGER PRIMARY KEY, song_id INTEGER REFERENCES songs(song_id));
                    INSERT INTO songs VALUES(42,7,1);
                    INSERT INTO track_sources VALUES(9,42,'/Volumes/Música/track.flac');
                    INSERT INTO playlist_songs VALUES(0,42),(1,42);
                    INSERT INTO play_history VALUES(18,42);
                ''')
                snapshot(library, root / 'export.sqlite')
                snapshot(root / 'export.sqlite', root / 'restore.sqlite')
                with sqlite3.connect(root / 'restore.sqlite') as restored:
                    for table in ['songs', 'track_sources', 'playlist_songs', 'play_history']:
                        self.assertEqual(conn.execute(f'SELECT * FROM {table}').fetchall(),
                                         restored.execute(f'SELECT * FROM {table}').fetchall())
                    self.assertEqual(restored.execute('PRAGMA foreign_key_check').fetchall(), [])
                with self.assertRaises(ValueError):
                    snapshot(library, root / 'restore.sqlite')

    def test_invalid_input_publishes_no_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with sqlite3.connect(root / 'invalid.sqlite') as conn:
                conn.execute('CREATE TABLE unrelated(id INTEGER)')
            with self.assertRaises(ValueError):
                snapshot(root / 'invalid.sqlite', root / 'destination.sqlite')
            self.assertFalse((root / 'destination.sqlite').exists())
            self.assertFalse(list(root.glob('.durvald-snapshot-*')))


if __name__ == '__main__':
    unittest.main()
