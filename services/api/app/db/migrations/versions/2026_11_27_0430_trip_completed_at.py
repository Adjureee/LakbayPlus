"""Add completed_at timestamp to trips table.

Revision ID: 2026_11_27_0430
Revises: 2026_11_27_0415

Additive only: adds nullable completed_at column for manual trip completion.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_27_0430"
down_revision: str | Sequence[str] | None = "2026_11_27_0415"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "trips",
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("trips", "completed_at")
