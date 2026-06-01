"""Make the agent's workspace package importable by the locked contract tests.

The acceptance suite lives here (locked, read-only to the agent); the
implementation under test lives in a separate workspace directory. The workspace
path is supplied by the harness via ``PWFG_WORKSPACE`` so the same locked tests
can run against a disposable run directory, a self-test temp dir, or the
committed stub — without the tests ever importing agent-writable test code.
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
