import argparse,datetime,hashlib,json,plistlib,subprocess,tempfile,os,shutil
from pathlib import Path

def run(args):
 return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT).strip()

def audit(app):
 subprocess.run(['codesign','--verify','--deep','--strict','--verbose=2',str(app)],check=True)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
 binary=app/'Contents/MacOS'/info['CFBundleExecutable']
 if not binary.is_file() or not os.access(binary,os.X_OK):raise RuntimeError('Main executable is missing or not executable')
 bad=[];binaries=[];external=[]
 root=app.resolve()
 for p in app.rglob('*'):
  if p.is_symlink():
   try: resolved=p.resolve(strict=True)
   except FileNotFoundError:bad.append(str(p));continue
   if not resolved.is_relative_to(root):external.append(str(p))
   continue
  if not p.is_file():continue
  with p.open('rb') as f:magic=f.read(4)
  if magic not in [bytes.fromhex(s) for s in ['feedface','feedfacf','cefaedfe','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']]:continue
  binaries.append(str(p.relative_to(app)))
  # otool treats a parenthesized filename as an archive member. Inspect a
  # neutral temporary copy for such paths, without changing the signed app.
  if '(' in str(p) or ')' in str(p):
   with tempfile.TemporaryDirectory(prefix='macho-inspection-') as scratch:
    neutral=Path(scratch)/'binary'
    shutil.copyfile(p,neutral)
    deps=run(['otool','-L',str(neutral)])
  else:
   deps=run(['otool','-L',str(p)])
  for line in deps.splitlines()[1:]:
   if not line.startswith(('\t',' ')):continue  # Skip per-architecture Mach-O headings
   dep=line.strip().split(' (',1)[0]
   if dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):external.append(f'{p.relative_to(app)} -> {dep}')
 if bad or external:raise RuntimeError(json.dumps({'broken_symlinks':bad,'external_dependencies':external},ensure_ascii=False))
 return info,{'mach_o_count':len(binaries),'broken_symlinks':bad,'external_non_system_dependencies':external,'architectures':run(['lipo','-archs',str(app/'Contents/MacOS'/info['CFBundleExecutable'])])}

p=argparse.ArgumentParser(description='Verify an app, archive it, and verify the extracted distribution payload.')
p.add_argument('--build-command-json',required=True);p.add_argument('--app',required=True);p.add_argument('--repo',default=str(Path(__file__).resolve().parents[1]));p.add_argument('--name',required=True);p.add_argument('--output',required=True);p.add_argument('--signing',required=True);p.add_argument('--app-name',required=True);p.add_argument('--bundle-id',required=True);p.add_argument('--source-snapshot',action='store_true');a=p.parse_args()
app=Path(a.app);out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
source_manifest = None
if a.source_snapshot:
 source_manifest = {}
 for folder in ['Sources','Resources','scripts']:
  for file in sorted((Path(a.repo)/folder).rglob('*')):
   if file.is_file(): source_manifest[str(file.relative_to(a.repo))]=hashlib.sha256(file.read_bytes()).hexdigest()
 assert source_manifest, 'No source files to fingerprint'
 commit='snapshot-'+hashlib.sha256(json.dumps(source_manifest,sort_keys=True).encode()).hexdigest()
else:
 assert Path(run(['git','-C',a.repo,'rev-parse','--show-toplevel'])).resolve()==Path(a.repo).resolve(), 'Not an independent repository'
 assert not run(['git','-C',a.repo,'status','--porcelain']), 'Working tree is dirty'
 commit=run(['git','-C',a.repo,'rev-parse','HEAD'])
build_command=json.loads(a.build_command_json)
assert isinstance(build_command,list) and build_command and all(isinstance(v,str) for v in build_command)
subprocess.run(build_command,cwd=a.repo,check=True)
if not a.source_snapshot:assert not run(['git','-C',a.repo,'status','--porcelain']), 'Build changed tracked source files'
info,checks=audit(app)
assert info['CFBundleIdentifier']==a.bundle_id, 'Unexpected bundle ID'
zipfile=out/a.name
assert not zipfile.exists(),zipfile
with tempfile.TemporaryDirectory(prefix='mac-personal-package-') as td:
 t=Path(td); staged=t/a.app_name
 subprocess.run(['ditto',str(app),str(staged)],check=True)
 subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(staged),str(t/a.name)],check=True)
 subprocess.run(['ditto','-x','-k',str(t/a.name),str(t/'extracted')],check=True)
 audit(t/'extracted'/a.app_name)
 shutil.copyfile(t/a.name,zipfile)
digest=hashlib.sha256()
with zipfile.open('rb') as stream:
 for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
h=digest.hexdigest()
(out/(a.name+'.sha256')).write_text(f'{h}  {a.name}\n')
meta={'source_commit':commit,'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundle_id':info['CFBundleIdentifier'],'minimum_macos':info.get('LSMinimumSystemVersion'),'signing':a.signing,'notarized':False,'archive_sha256':h,'checks':checks,'archive_extraction_signature_verified':True,'xcode':run(['xcodebuild','-version']),'build_host_os':run(['sw_vers','-productVersion']),'build_command':build_command,'source_was_clean':not a.source_snapshot,'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
if source_manifest:meta['source_files_sha256']=source_manifest
(out/(a.name+'.build-info.json')).write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta,ensure_ascii=False,indent=2))
