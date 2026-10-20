"""Bundle the repository-matched assets; never bundle proprietary RCT2 data."""
import hashlib, json, pathlib, shutil, subprocess, sys, urllib.request, zipfile
root = pathlib.Path(__file__).resolve().parents[3]
out = root / 'build/ios-data'
out.mkdir(parents=True, exist_ok=True)
for folder in ('language', 'scenario_patches', 'shaders'):
    shutil.copytree(root/'data'/folder, out/folder, dirs_exist_ok=True)
for name in ('g2', 'fonts', 'palettes', 'tracks'):
    shutil.copy2(root/f'build/ipad-host/{name}.dat', out)
for name, target in [('objects','object'), ('title-sequences','sequence'), ('opensfx',''), ('openmusic','')]:
    asset=json.loads((root/'assets.json').read_text())[name]
    archive=root/f'build/{name}.zip'
    if not archive.exists(): urllib.request.urlretrieve(asset['url'], archive)
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==asset['sha256'], name
    with zipfile.ZipFile(archive) as z:
        for member in z.infolist():
            path=pathlib.PurePosixPath(member.filename)
            if path.is_absolute() or '..' in path.parts: raise ValueError(member.filename)
        z.extractall(out/target)
for name in ('licence.txt','contributors.md','PRIVACY.md'):
    shutil.copy2(root/name,out)
shutil.copy2(root/'distribution/changelog.txt', out/'changelog.txt')
subprocess.run([sys.executable, str(root/"src/openrct2-ios/scripts/fetch-fonts.py"), str(out/"fonts")], check=True)
print(out)
