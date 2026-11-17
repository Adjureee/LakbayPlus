"""Register an admin account on a running Lakbay API.

Run it yourself. It asks for the email, password and admin registration code with
hidden input, so none of them end up in shell history, logs or a chat. Nothing
secret is printed, and the returned tokens are discarded.

    python scripts/register_admin.py
    python scripts/register_admin.py --base-url https://lakbay-api.onrender.com/api/v1

The admin registration code is the ADMIN_REGISTRATION_CODE value in Render's
Environment tab (or your local .env for a local API). Use a dedicated test email
and a password you do not use anywhere else.
"""

import argparse
import getpass
import json
import sys
import urllib.error
import urllib.request

DEFAULT_BASE_URL = "http://127.0.0.1:8000/api/v1"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--full-name", default="Test Admin")
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")

    print(f"API: {base_url}")
    email = input("Admin email: ").strip()
    password = getpass.getpass("Password (8+ characters, hidden): ")
    confirm = getpass.getpass("Confirm password (hidden): ")
    if password != confirm:
        print("The passwords do not match. Nothing was sent.")
        return 1
    code = getpass.getpass("Admin registration code (hidden): ")

    body = json.dumps(
        {
            "full_name": args.full_name,
            "email": email,
            "password": password,
            "confirm_password": confirm,
            "admin_registration_code": code,
        }
    ).encode()
    request = urllib.request.Request(
        f"{base_url}/auth/register/admin",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        # The first call can take a while if the free instance was asleep.
        with urllib.request.urlopen(request, timeout=90) as response:
            user = json.load(response).get("user", {})
    except urllib.error.HTTPError as error:
        try:
            detail = json.load(error).get("error", {})
        except Exception:  # noqa: BLE001 - show the status instead
            detail = {}
        print(f"Registration failed ({error.code}): {detail.get('message', 'no details')}")
        details = detail.get("details")
        if isinstance(details, list):
            for item in details:
                if isinstance(item, dict):
                    where = ".".join(str(p) for p in item.get("loc", []) if p != "body")
                    print(f"  - {where}: {item.get('msg')}")
        return 1
    except OSError as error:
        print(f"Could not reach the API: {error}")
        return 1

    print(f"Admin account created: {user.get('email')} (role: {user.get('role')}).")
    print("Sign in to the admin app with that email and the password you chose.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
