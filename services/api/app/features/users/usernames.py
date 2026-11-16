"""Usernames: how travelers find and invite each other.

A username is 3-30 lowercase letters, digits, dots or underscores. It is unique
without regard to case. Users created before usernames existed get one made from
their name (see the migration), and new accounts get one when they register.
"""

import re

USERNAME_PATTERN = re.compile(r"^[a-z0-9_.]{3,30}$")
USERNAME_RULE = "Use 3 to 30 letters, numbers, dots or underscores."


def normalize_username(value: str) -> str:
    """Trim, drop a leading @ and lowercase."""
    return value.strip().removeprefix("@").strip().lower()


def is_valid_username(value: str) -> bool:
    return bool(USERNAME_PATTERN.match(value))


def username_seed(full_name: str, email: str) -> str:
    """A readable starting point: the name, else the part of the email before @."""
    for source in (full_name, email.split("@", 1)[0]):
        seed = re.sub(r"[^a-z0-9]+", "", source.lower())[:24]
        if len(seed) >= 3:
            return seed
    return "traveler"


def with_suffix(seed: str, attempt: int) -> str:
    """The seed itself first, then seed2, seed3, ... within the length limit."""
    if attempt <= 1:
        return seed
    suffix = str(attempt)
    return seed[: 30 - len(suffix)] + suffix
