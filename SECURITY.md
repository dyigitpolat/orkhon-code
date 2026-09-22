# Security and data handling

Orkhon has no account system, telemetry, credential store or network service. Opening an SSH workspace invokes the installed OpenSSH client and honors its configuration, agent and host verification. The askpass helper only returns a prompt response to the requesting SSH process; it does not save or log passwords. Private control sockets and temporary files use restricted directories.

HTML preview is an intentional browser capability: page scripts run and remote resources may load. It uses nonpersistent WebKit storage with no privileged native bridge. Only preview trusted local HTML if its scripts should access file-origin resources. Markdown uses Foundation and TextKit without executing HTML scripts.

Filesystem saves are optimistic and atomic, preserving file permissions. Conflicts keep the edited buffer intact until reviewed. Recovery snapshots contain document text and are stored with private permissions in the user's Application Support directory. They are not an encrypted backup.

For a suspected security or data-loss defect, contact the maintainer through the repository's private vulnerability-reporting channel when one is available. Include a minimal synthetic reproduction, macOS version and build revision. Do not post passwords, private keys or personal documents in public issues.
