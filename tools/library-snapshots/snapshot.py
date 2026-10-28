#!/usr/bin/env python3
"""Export/restore a complete SQLite library to a NEW destination, without network."""
import argparse
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import tempfile


def path_key(value):
    if not value.startswith('/') or '\0' in value or value.endswith('/'):
        raise ValueError('Invalid local media path')
    parts = [part for part in value.split('/') if part not in ('', '.')]
    if not parts:
        raise ValueError('Invalid local media path')
    return '/' + '/'.join(parts)


def snapshot(source, destination):
    source = Path(source).resolve(strict=True)
    destination = Path(destination).absolute()
    if destination.exists():
        raise ValueError('Destination must be a new file; existing libraries are never overwritten')
    if not destination.parent.is_dir():
        raise ValueError('Destination directory does not exist')
    handle, temporary = tempfile.mkstemp(prefix='.durvald-snapshot-', dir=destination.parent)
    os.close(handle)
    try:
        # URI encoding handles paths with spaces, #, ? and Unicode.
        with closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)) as original:
            original.create_function('durvald_local_path_key', 1, path_key, deterministic=True)
            with closing(sqlite3.connect(temporary)) as copy:
                copy.create_function('durvald_local_path_key', 1, path_key, deterministic=True)
                original.backup(copy)
                if copy.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                    raise ValueError('Snapshot failed integrity verification')
                if copy.execute('PRAGMA foreign_key_check').fetchall():
                    raise ValueError('Snapshot contains broken relationships')
                if not copy.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='songs'").fetchone():
                    raise ValueError('Source is not a Durvald library')
        # No-clobber atomic publication, including if two exports race.
        with open(temporary, 'rb') as saved:
            os.fsync(saved.fileno())
        os.link(temporary, destination)
    finally:
        os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['export', 'restore'])
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        snapshot(args.source, args.destination)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'{error}\n')
    print(f'{args.action}: {args.destination}')


if __name__ == '__main__':
    main()
