"""Saved itinerary timelines with a revision log.

Revision ID: 2026_11_25_0900
Revises: 2026_11_24_0900

Step T4 of docs/ITINERARY_TIMELINE_DESIGN.md. Additive only: one new table,
trip_timeline_revisions (trip, revision number, the planning state, the timeline the
server built from it, the sentences describing what changed, who saved it and when).
Nothing that exists changes. Deleting a trip deletes its revisions.

Run on Neon BEFORE deploying the code: the new endpoints read this table.

Downgrade drops the table (and the saved revisions in it).
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_25_0900"
down_revision: str | Sequence[str] | None = "2026_11_24_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "trip_timeline_revisions",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "trip_id", sa.Integer(),
            sa.ForeignKey("trips.trip_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("state", sa.JSON(), nullable=False),
        sa.Column("timeline", sa.JSON(), nullable=False),
        sa.Column("changes", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column(
            "created_by_user_id", sa.Integer(),
            sa.ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True,
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False,
            server_default=sa.func.now(),
        ),
        sa.UniqueConstraint("trip_id", "revision", name="uq_trip_timeline_revision"),
        sa.CheckConstraint("revision >= 1", name="ck_trip_timeline_revision_positive"),
    )
    op.create_index(
        "ix_trip_timeline_revisions_trip_id", "trip_timeline_revisions", ["trip_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_trip_timeline_revisions_trip_id", table_name="trip_timeline_revisions")
    op.drop_table("trip_timeline_revisions")
