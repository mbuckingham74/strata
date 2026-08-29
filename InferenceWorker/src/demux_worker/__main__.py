"""Entry point for python -m demux_worker"""

import sys

if len(sys.argv) > 1 and sys.argv[1] == "prepare-model":
    from .prepare_model import main as pm
    # shift args
    sys.argv = [sys.argv[0]] + sys.argv[2:]
    pm()
else:
    from .worker import main
    main()
