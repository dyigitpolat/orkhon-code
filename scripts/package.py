#!/usr/bin/env python3
from pathlib import Path
import json,plistlib,shutil,subprocess,os,tempfile,sys
root=Path(__file__).resolve().parent.parent
preview='--preview' in sys.argv
stage=Path(tempfile.mkdtemp(prefix='orkhon-review-' if preview else 'orkhon-package-'))
app=stage/'Orkhon Code.app';contents=app/'Contents';resources=contents/'Resources';macos=contents/'MacOS'
resources.mkdir(parents=True,exist_ok=True);macos.mkdir(exist_ok=True)
shutil.copy2(root/'.build/release/Lumen',macos/'Orkhon Code')
for name in ['languages.json','supported-extensions.json']:
 shutil.copy2(root/'Resources'/name,resources/name)
shutil.copy2(root/'Resources/workspace_watch.py',resources/'workspace_watch.py')
for p in (root/'Resources').glob('*.md'):shutil.copy2(p,resources/p.name)
shutil.copytree(root/'Resources/MarkdownPreview',resources/'MarkdownPreview')
# Broad syntax detection never claims ownership of file types. System text types
# carry an icon but rank None so registration alone cannot become a default.
info={'CFBundleName':'Orkhon Code','CFBundleDisplayName':'Orkhon Code','CFBundleExecutable':'Orkhon Code','CFBundleIdentifier':'app.orkhon.editor.review' if preview else 'app.orkhon.editor','CFBundleVersion':'14','CFBundleShortVersionString':'1.6.3','CFBundlePackageType':'APPL','CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,'NSSupportsAutomaticGraphicsSwitching':True,'LSMinimumSystemVersion':'13.0','NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'Orkhon Code · Open-source component licenses in Resources.'}
if not preview:
 helper=stage/'document-types'
 subprocess.run(['swiftc','-O','-module-cache-path',str(root/'work/module-cache'),str(root/'Sources/Lumen/AssociationPolicy.swift'),str(root/'scripts/document_types.swift'),'-o',str(helper)],check=True)
 source_types=json.loads(subprocess.check_output([str(helper)]))
 if not source_types:raise RuntimeError('macOS file-type services returned no source types. Run packaging with access to the logged-in user session; refusing to ship an empty setup list.')
 info['CFBundleDocumentTypes']=[{'CFBundleTypeName':'Text and Source Code','CFBundleTypeRole':'Editor','LSHandlerRank':'None','CFBundleTypeIconFile':'DocumentIcon.icns','LSItemContentTypes':source_types['types']+['public.text','public.source-code']}]
 # Extension-only records are necessary for formats that macOS represents with
 # dynamic UTIs. LSItemContentTypes takes precedence, so keep these separate.
 info['CFBundleDocumentTypes'].append({'CFBundleTypeName':'Text and Source Extensions','CFBundleTypeRole':'Editor','LSHandlerRank':'None','CFBundleTypeIconFile':'DocumentIcon.icns','CFBundleTypeExtensions':source_types['extensions']})
if not preview:info['UTImportedTypeDeclarations']=[{'UTTypeIdentifier':'net.daringfireball.markdown','UTTypeDescription':'Markdown document','UTTypeConformsTo':['public.plain-text'],'UTTypeTagSpecification':{'public.filename-extension':['md'],'public.mime-type':'text/markdown'}}]
info['NSAppTransportSecurity']={'NSAllowsArbitraryLoadsInWebContent':True}
helper_app=contents/'Helpers/Orkhon SSH Authentication.app'
helper_contents=helper_app/'Contents';helper_binary=helper_contents/'MacOS/OrkhonSSHAskpass'
helper_binary.parent.mkdir(parents=True)
shutil.copy2(root/'.build/release/SSHAskpass',helper_binary)
(helper_contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.orkhon.editor.ssh-auth','CFBundleName':'Orkhon SSH Authentication','CFBundleExecutable':'OrkhonSSHAskpass','CFBundlePackageType':'APPL','CFBundleVersion':info['CFBundleVersion'],'CFBundleShortVersionString':info['CFBundleShortVersionString'],'LSUIElement':True,'LSMinimumSystemVersion':'13.0','NSPrincipalClass':'NSApplication'}))
signing=os.environ.get('ORKHON_SIGN_IDENTITY','-')
subprocess.run(['codesign','--force','--sign',signing,'--options','runtime',str(helper_app)],check=True)
with (contents/'Info.plist').open('wb') as f:plistlib.dump(info,f)
(contents/'PkgInfo').write_bytes(b'APPL????')
licenses=resources/'Licenses';licenses.mkdir(exist_ok=True)
for name,src in [('Scintilla.txt','Vendor/scintilla/License.txt'),('Lexilla.txt','Vendor/lexilla/License.txt'),('SciTE.txt','Vendor/scite/License.txt'),('SwiftTerm.txt','Vendor/SwiftTerm/LICENSE')]:
 p=root/src
 if not p.exists() and name=='SwiftTerm.txt':p=root/'Vendor/SwiftTerm/LICENSE.txt'
 shutil.copy2(p,licenses/name)
shutil.copytree(root/'Vendor/MarkdownPreview',licenses/'MarkdownPreview')
shutil.copy2(root/'Vendor/SwiftTerm/ORKHON-PATCHES.md',licenses/'SwiftTerm-Patches.md')
for p in (root/'Vendor/scintilla/cocoa/res').glob('*.png'):shutil.copy2(p,resources/p.name)
if (root/'work/DocumentIcon.icns').exists():shutil.copy2(root/'work/DocumentIcon.icns',resources/'DocumentIcon.icns')
if (root/'work/AppIcon.icns').exists():shutil.copy2(root/'work/AppIcon.icns',resources/'AppIcon.icns')
for name in ["mac_cursor_busy","mac_cursor_flipped"]:
 subprocess.run(["sips","-s","format","tiff",str(root/"Vendor/scintilla/cocoa/res"/(name+".png")),"--out",str(resources/(name+".tiff"))],check=True,stdout=subprocess.DEVNULL)
for attribute in ["com.apple.FinderInfo","com.apple.ResourceFork"]:
 subprocess.run(["xattr","-dr",attribute,str(app)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['codesign','--force','--sign',signing,'--options','runtime',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
# Never write over a runnable app. Every signed stage has a new path and inode.
(root/('work/review-app-path.txt' if preview else 'work/staged-app-path.txt')).write_text(str(app))
print(app)
