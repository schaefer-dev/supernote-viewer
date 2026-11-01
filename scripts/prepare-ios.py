#!/usr/bin/env python3
"""Read only DROPBOX_APP_KEY as data. Never execute .env or emit its contents."""
import argparse
from pathlib import Path
import re

def prepare(source: Path, destination: Path):
    key = None
    for line in source.read_text().splitlines():
        match = re.fullmatch(r'\s*(?:export\s+)?DROPBOX_APP_KEY\s*=\s*([A-Za-z0-9]+|"[A-Za-z0-9]+"|\'[A-Za-z0-9]+\')\s*', line)
        if match:
            if key is not None:
                raise ValueError('Duplicate app key')
            key = match[1].strip('\"\'')
    if not key:
        raise ValueError('Set a valid DROPBOX_APP_KEY in the local .env file')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('// Generated locally; contains only the public app key.\nDROPBOX_APP_KEY = ' + key + '\n')
    destination.chmod(0o600)

if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument('--env', type=Path, default=root / '.env')
    parser.add_argument('--output', type=Path, default=root / 'ViewerIOS/Configuration/Local.xcconfig')
    args = parser.parse_args()
    try:
        prepare(args.env, args.output)
    except (ValueError, OSError):
        parser.exit(1, 'Could not prepare iOS configuration. Check DROPBOX_APP_KEY and file permissions.\n')
    print('Prepared local iOS configuration.')
