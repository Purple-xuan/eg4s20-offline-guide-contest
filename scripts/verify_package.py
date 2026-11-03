"""Verify immutable delivery files and project/include references."""
from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'package_manifest.json').read_text(encoding='utf-8'))
for row in manifest['files']:
    path = root / row['path']
    assert path.is_file(), f"Missing file: {row['path']}"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], f"Checksum mismatch: {row['path']}"
    assert path.stat().st_size == row['bytes'], f"Size mismatch: {row['path']}"
for project_name in ['official_example.al', 'official_example.prj']:
    project = root / 'prj' / project_name
    for node in ET.parse(project).findall('.//Source_Files//File'):
        target = (project.parent / node.get('Path')).resolve()
        assert root in target.parents and target.is_file(), f"Bad reference: {node.get('Path')}"
for path in (root / 'src').rglob('*'):
    if path.suffix.lower() not in {'.v', '.vh'}:
        continue
    for include in re.findall(r'`include\s+"([^"\r\n]+)"', path.read_text(encoding='utf-8', errors='replace')):
        assert (path.parent / include).is_file(), f"Missing include: {path}: {include}"
print(f"PACKAGE_VERIFY_PASS files={len(manifest['files'])}")
