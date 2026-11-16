"""Usernames and trip invitations.

Revision ID: 2026_11_17_0900
Revises: 2026_11_16_1100

- users.username: 3-30 characters, unique without regard to case. Existing users
  get one made from their name (or the part of their email before the @), with
  _2, _3, ... added when it is taken. They can change it later.
- trip_members.status accepts 'invited' (an invitation not yet answered).
- notifications.event_type accepts trip_invitation, trip_invitation_accepted and
  trip_invitation_declined.

Downgrade: pending invitations (status 'invited') are deleted and invitation
notifications are removed, because the older constraints do not allow them.
Usernames are dropped.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_17_0900"
down_revision: str | Sequence[str] | None = "2026_11_16_1100"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

OLD_EVENTS = (
    "'trip_member_added', 'task_assigned', 'task_updated', 'expense_created', "
    "'expense_updated', 'expense_voided', 'trip_updated', 'trip_route_updated'"
)
NEW_EVENTS = (
    "'trip_member_added', 'trip_invitation', 'trip_invitation_accepted', "
    "'trip_invitation_declined', 'task_assigned', 'task_updated', 'expense_created', "
    "'expense_updated', 'expense_voided', 'trip_updated', 'trip_route_updated'"
)


# One statement so it also works when the SQL is generated offline. The seed is
# the name, else the part of the email before the @, else "traveler" (letters and
# digits only, at most 24). People who share a seed get seed, seed_2, seed_3, ...
# in sign-up order; the underscore cannot appear in a seed, so these never clash.
BACKFILL_USERNAMES = """
WITH seeds AS (
    SELECT
        user_id,
        CASE
            WHEN length(left(regexp_replace(lower(full_name), '[^a-z0-9]+', '', 'g'), 24)) >= 3
                THEN left(regexp_replace(lower(full_name), '[^a-z0-9]+', '', 'g'), 24)
            WHEN length(left(regexp_replace(lower(split_part(email, '@', 1)), '[^a-z0-9]+', '', 'g'), 24)) >= 3
                THEN left(regexp_replace(lower(split_part(email, '@', 1)), '[^a-z0-9]+', '', 'g'), 24)
            ELSE 'traveler'
        END AS seed
    FROM users
), numbered AS (
    SELECT
        user_id,
        seed,
        row_number() OVER (PARTITION BY seed ORDER BY user_id) AS position
    FROM seeds
)
UPDATE users
SET username = CASE
    WHEN numbered.position = 1 THEN numbered.seed
    ELSE numbered.seed || '_' || numbered.position
END
FROM numbered
WHERE users.user_id = numbered.user_id
"""


def upgrade() -> None:
    op.add_column("users", sa.Column("username", sa.String(30), nullable=True))

    op.execute(BACKFILL_USERNAMES)

    op.create_index(
        "uq_users_username_lower", "users", [sa.text("lower(username)")], unique=True
    )

    op.drop_constraint("ck_trip_members_status", "trip_members", type_="check")
    op.create_check_constraint(
        "ck_trip_members_status",
        "trip_members",
        "status IN ('active', 'removed', 'invited')",
    )

    op.drop_constraint("ck_notifications_event_type", "notifications", type_="check")
    op.create_check_constraint(
        "ck_notifications_event_type",
        "notifications",
        f"event_type IN ({NEW_EVENTS})",
    )


def downgrade() -> None:
    op.execute("DELETE FROM notifications WHERE event_type IN "
               "('trip_invitation', 'trip_invitation_accepted', 'trip_invitation_declined')")
    op.drop_constraint("ck_notifications_event_type", "notifications", type_="check")
    op.create_check_constraint(
        "ck_notifications_event_type", "notifications", f"event_type IN ({OLD_EVENTS})"
    )

    op.execute("DELETE FROM trip_members WHERE status = 'invited'")
    op.drop_constraint("ck_trip_members_status", "trip_members", type_="check")
    op.create_check_constraint(
        "ck_trip_members_status", "trip_members", "status IN ('active', 'removed')"
    )

    op.drop_index("uq_users_username_lower", table_name="users")
    op.drop_column("users", "username")
