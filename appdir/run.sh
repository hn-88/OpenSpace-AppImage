#!/bin/bash

if [ -z "${OPENSPACE_USER}" ]; then
    export OPENSPACE_USER="${HOME}/OpenSpace/user"
    echo "OPENSPACE_USER is not set. Defaulting to: ${OPENSPACE_USER}"
    echo "To override, set it before launching:"
    echo "  export OPENSPACE_USER=/path/to/your/openspace/user"
fi
export QT_PLUGIN_PATH=lib/x86_64-linux-gnu/qt6/plugins/
exec "$@"
