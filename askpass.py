#!/usr/bin/env python3
"""SSH_ASKPASS helper: answers ssh's password prompt from the system keychain.

ssh runs this with the prompt text as argv[1] and reads the answer from stdout.
Anything that isn't a password prompt (host-key confirmation, etc.) is refused
so ssh fails instead of us guessing.
"""
import os
import sys

import keyring

prompt = sys.argv[1] if len(sys.argv) > 1 else ""
p = prompt.lower()
duo_option = os.environ.get("BABEL_UI_DUO_OPTION", "1")

if "password" in p:
    pw = keyring.get_password("babel-ui", os.environ.get("BABEL_UI_ACCOUNT", "babel"))
    if not pw:
        sys.exit(1)
    print(pw)
elif "passcode or option" in p and duo_option:
    # Duo: at CMU option 1 is "Duo Push" — approve it on your phone.
    print(duo_option)
else:
    sys.exit(1)
