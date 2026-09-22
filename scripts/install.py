#!/usr/bin/env python3
"""Open the built installer; defaults are reviewed inside Orkhon on first launch."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
installer=root/'outputs/Orkhon Editor Installer.pkg'
if not installer.exists():subprocess.run([str(root/'scripts/build.sh')],check=True)
subprocess.run(['open',str(installer)],check=True)
