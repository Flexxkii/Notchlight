#!/bin/zsh
# Root legal documents are canonical; SwiftPM requires resources inside its target.
set -euo pipefail
legal_project_dir="${0:A:h:h}"
legal_resource_dir="$legal_project_dir/Sources/Notchlight/Resources/Legal"
if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--check" ]]; }; then
    print -u2 "usage: $0 [--check]"
    exit 2
fi
if (( $# == 0 )); then
    mkdir -p "$legal_resource_dir"
fi
for legal_file in LICENSE TERMS.md PRIVACY.md THIRD_PARTY_NOTICES.md; do
    if (( $# == 1 )); then
        if ! cmp -s "$legal_project_dir/$legal_file" "$legal_resource_dir/$legal_file"; then
            print -u2 "Legal resource differs: $legal_file. Run ./scripts/sync-legal.sh."
            exit 1
        fi
    else
        cp "$legal_project_dir/$legal_file" "$legal_resource_dir/$legal_file"
    fi
done
