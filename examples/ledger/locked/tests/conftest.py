"""Put the agent's workspace package on the path for the locked contract tests.

The implementation under test lives in a separate workspace dir supplied by the
harness via PWFG_WORKSPACE; the locked tests never import agent-writable test code.
"""

import os
import sys
from pathlib import Path


def _workspace() -> str:
    env = os.environ.get("PWFG_WORKSPACE")
    if env:
        return env
    return str(Path(__file__).parents[2] / "workspace")


sys.path.insert(0, _workspace())
