"""Read-only pre-release cutover export. Never opens the legacy store for writes."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--store', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
with sqlite3.connect(args.store.resolve().as_uri() + '?mode=ro', uri=True) as db:
    rows = db.execute('''SELECT ZMUSICPLAYLISTID, ZNAME, ZROLERAWVALUE,
        ZWRITEPOLICYRAWVALUE, ZSORTORDER FROM ZPLAYLISTRECORD
        WHERE ZISACTIVE = 1 AND ZROLERAWVALUE IN ('oneTruePlaylist', 'triageSource')
        ORDER BY ZSORTORDER, ZMUSICPLAYLISTID''').fetchall()
assert sum(row[2] == 'oneTruePlaylist' for row in rows) == 1, 'Expected exactly one Overplay playlist'
assert len({row[0] for row in rows}) == len(rows), 'Duplicate configured source IDs'
result = {'version': 2, 'rebuildID': str(uuid.uuid4()), 'playlists': [dict(zip(
    ['musicPlaylistID', 'name', 'role', 'writePolicy', 'sortOrder'], row)) for row in rows]}
with args.output.open('x') as output:
    os.chmod(args.output, 0o600)
    json.dump(result, output, indent=2)
    output.write('\n')
assert json.loads(args.output.read_text()) == result
print(f'Verified {len(rows)} source links; no tracks or activity exported. {args.output}')
