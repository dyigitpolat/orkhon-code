#!/usr/bin/env python3
"""Create a local macOS package without installing or modifying file defaults."""
from pathlib import Path
import tempfile,subprocess,shutil,plistlib,os
root=Path(__file__).resolve().parent.parent
app=Path((root/'work/staged-app-path.txt').read_text().strip())
version=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
stage=Path(tempfile.mkdtemp(prefix='orkhon-installer-'))
payload=stage/'payload';apps=payload/'Applications';apps.mkdir(parents=True)
shutil.copytree(app,apps/app.name,copy_function=shutil.copy)
component=stage/'component.plist'
component.write_bytes(plistlib.dumps([{'RootRelativeBundlePath':'Applications/Orkhon Code.app','BundleIsRelocatable':False,'BundleIsVersionChecked':True,'BundleHasStrictIdentifier':True,'BundleOverwriteAction':'upgrade'}]))
scripts=stage/'scripts';scripts.mkdir()
preinstall=scripts/'preinstall'
helper=stage/'scripts/capture-associations'
helper_source=stage/'main.swift';shutil.copyfile(root/'scripts/capture_associations.swift',helper_source)
subprocess.run(['swiftc','-O','-module-cache-path',str(root/'work/module-cache'),'-target','arm64-apple-macosx13.0',str(root/'Sources/Lumen/AssociationPolicy.swift'),str(helper_source),'-o',str(helper)],check=True)
preinstall.write_text('''#!/bin/sh
if /usr/bin/pgrep -x "Orkhon Code" >/dev/null || /usr/bin/pgrep -x "Orkhon Editor" >/dev/null; then
 echo "Please quit Orkhon Code before installing." >&2
 exit 1
fi
console_user=$(/usr/bin/stat -f '%Su' /dev/console)
console_uid=$(/usr/bin/stat -f '%u' /dev/console)
if [ "$console_uid" -ge 501 ] && [ "$console_user" != "loginwindow" ]; then
 /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" "$(dirname "$0")/capture-associations" || exit 1
fi
exit 0
''');preinstall.chmod(0o755)
postinstall=scripts/'postinstall'
postinstall.write_text('''#!/bin/sh
# Remove only the previous product bundle after the new payload is in place.
legacy="${3%/}/Applications/Orkhon Editor.app"
legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null)
if [ "$legacy_id" = "app.orkhon.editor" ] && [ -x "${3%/}/Applications/Orkhon Code.app/Contents/MacOS/Orkhon Code" ]; then
 /bin/rm -rf -- "$legacy"
fi
console_user=$(/usr/bin/stat -f '%Su' /dev/console)
console_uid=$(/usr/bin/stat -f '%u' /dev/console)
if [ "$3" = "/" ] && [ "$console_uid" -ge 501 ] && [ "$console_user" != "loginwindow" ]; then
 /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/open -a "/Applications/Orkhon Code.app" --args --welcome
fi
exit 0
''');postinstall.chmod(0o755)
subprocess.run(['pkgbuild','--root',str(payload),'--identifier','app.orkhon.editor','--version',version,'--install-location','/','--component-plist',str(component),'--scripts',str(scripts),str(stage/'OrkhonComponent.pkg')],check=True)
resources=stage/'resources';resources.mkdir()
(resources/'welcome.html').write_text('''<html><head><meta charset="utf-8"></head><body style="font-family:-apple-system;font-size:13px;color:#293344"><h1 style="font-size:26px">Orkhon Code</h1><p>A small, native editor for text and code.</p><p>This installer places Orkhon Code in Applications. Quit any running copy before continuing.</p><p>On first launch, review the recommended text and source-file defaults and deselect any you want to keep. Nothing changes until you confirm. macOS 26.4 and later also requires approval for each changed file type; setup shows the count before starting and lets you stop. Browser, media, design, and ambiguous file formats keep their current apps.</p><p>For Apple silicon Macs running macOS 13 or later.</p></body></html>''')
(resources/'finish.html').write_text('''<html><head><meta charset="utf-8"></head><body style="font-family:-apple-system;font-size:13px;color:#293344"><h1 style="font-size:25px">Orkhon Code is installed.</h1><p>Orkhon Code opens automatically with its welcome page. You can also find it in <b>Applications</b>.</p><p>Review the suggested text and source-file defaults in the welcome setup. Deselect any exceptions, then confirm, or keep all current defaults.</p><p>Your document files stay where they are.</p></body></html>''')
(stage/'distribution.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>Orkhon Code</title><organization>app.orkhon</organization>
<welcome file="welcome.html"/><conclusion file="finish.html"/>
<options customize="never" require-scripts="false" hostArchitectures="arm64"/>
<volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<choices-outline><line choice="default"/></choices-outline>
<choice id="default" visible="false" title="Orkhon Code"><pkg-ref id="app.orkhon.editor"/></choice>
<pkg-ref id="app.orkhon.editor" version="{version}" onConclusion="none">OrkhonComponent.pkg</pkg-ref>
</installer-gui-script>''')
destination=root/'outputs/Orkhon Code Installer.pkg'
destination.parent.mkdir(parents=True,exist_ok=True)
signing=['--sign',os.environ['ORKHON_INSTALLER_SIGN_IDENTITY']] if os.environ.get('ORKHON_INSTALLER_SIGN_IDENTITY') else []
subprocess.run(['productbuild']+signing+['--distribution',str(stage/'distribution.xml'),'--resources',str(resources),'--package-path',str(stage),str(stage/'Orkhon Code Installer.pkg')],check=True)
shutil.copyfile(stage/'Orkhon Code Installer.pkg',destination)
(root/'work/installer-stage-path.txt').write_text(str(stage))
print(destination)
