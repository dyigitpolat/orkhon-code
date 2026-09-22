#!/usr/bin/env python3
"""Create a local macOS package without installing or modifying file defaults."""
from pathlib import Path
import tempfile,subprocess,shutil,plistlib,os
root=Path(__file__).resolve().parent.parent
app=Path((root/'work/staged-app-path.txt').read_text().strip())
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
stage=Path(tempfile.mkdtemp(prefix='orkhon-installer-'))
payload=stage/'payload';apps=payload/'Applications';apps.mkdir(parents=True)
shutil.copytree(app,apps/app.name,copy_function=shutil.copy)
component=stage/'component.plist'
component.write_bytes(plistlib.dumps([{'RootRelativeBundlePath':'Applications/Orkhon Editor.app','BundleIsRelocatable':False,'BundleIsVersionChecked':True,'BundleHasStrictIdentifier':True,'BundleOverwriteAction':'upgrade'}]))
scripts=stage/'scripts';scripts.mkdir()
preinstall=scripts/'preinstall'
helper=stage/'scripts/capture-associations'
helper_source=stage/'main.swift';shutil.copyfile(root/'scripts/capture_associations.swift',helper_source)
subprocess.run(['swiftc','-O','-module-cache-path',str(root/'work/module-cache'),'-target','arm64-apple-macosx13.0',str(root/'Sources/Lumen/AssociationPolicy.swift'),str(helper_source),'-o',str(helper)],check=True)
preinstall.write_text('''#!/bin/sh
if /usr/bin/pgrep -x "Orkhon Editor" >/dev/null; then
 echo "Please quit Orkhon Editor before installing." >&2
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
console_user=$(/usr/bin/stat -f '%Su' /dev/console)
console_uid=$(/usr/bin/stat -f '%u' /dev/console)
if [ "$3" = "/" ] && [ "$console_uid" -ge 501 ] && [ "$console_user" != "loginwindow" ]; then
 /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/open -a "/Applications/Orkhon Editor.app" --args --welcome
fi
exit 0
''');postinstall.chmod(0o755)
subprocess.run(['pkgbuild','--root',str(payload),'--identifier','app.orkhon.editor','--version','1.3.0','--install-location','/','--component-plist',str(component),'--scripts',str(scripts),str(stage/'OrkhonComponent.pkg')],check=True)
resources=stage/'resources';resources.mkdir()
(resources/'welcome.html').write_text('''<html><head><meta charset="utf-8"></head><body style="font-family:-apple-system;font-size:13px;color:#293344"><h1 style="font-size:26px">Orkhon Editor</h1><p>new document: here is a little room to think.</p><p>A small, native editor for text and code.</p><p>This installer places Orkhon Editor in Applications. Quit any running copy before continuing.</p><p>On first launch, review the recommended source-file defaults and deselect any you want to keep. Nothing changes until you confirm. Browser, media, design, and ambiguous file formats keep their current apps.</p><p>For Apple silicon Macs running macOS 13 or later.</p></body></html>''')
(resources/'finish.html').write_text('''<html><head><meta charset="utf-8"></head><body style="font-family:-apple-system;font-size:13px;color:#293344"><h1 style="font-size:25px">Orkhon Editor is installed.</h1><p>Orkhon Editor opens automatically with its welcome page. You can also find it in <b>Applications</b>.</p><p>Review the suggested source-file defaults in the welcome setup. Deselect any exceptions, then confirm, or keep all current defaults.</p><p>Your document files stay where they are.</p></body></html>''')
(stage/'distribution.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>Orkhon Editor</title><organization>app.orkhon</organization>
<welcome file="welcome.html"/><conclusion file="finish.html"/>
<options customize="never" require-scripts="false" hostArchitectures="arm64"/>
<volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<choices-outline><line choice="default"/></choices-outline>
<choice id="default" visible="false" title="Orkhon Editor"><pkg-ref id="app.orkhon.editor"/></choice>
<pkg-ref id="app.orkhon.editor" version="1.3.0" onConclusion="none">OrkhonComponent.pkg</pkg-ref>
</installer-gui-script>''')
destination=root/'outputs/Orkhon Editor Installer.pkg'
destination.parent.mkdir(parents=True,exist_ok=True)
signing=['--sign',os.environ['ORKHON_INSTALLER_SIGN_IDENTITY']] if os.environ.get('ORKHON_INSTALLER_SIGN_IDENTITY') else []
subprocess.run(['productbuild']+signing+['--distribution',str(stage/'distribution.xml'),'--resources',str(resources),'--package-path',str(stage),str(stage/'Orkhon Editor Installer.pkg')],check=True)
shutil.copyfile(stage/'Orkhon Editor Installer.pkg',destination)
(root/'work/installer-stage-path.txt').write_text(str(stage))
print(destination)
