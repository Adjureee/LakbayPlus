"""Add admin-editable access_trail_polyline on destinations.

Revision ID: 2026_11_16_1100
Revises: 2026_11_16_1000

Allows administrators to define a custom polyline5 road/trail path from the
mapped road entry point or arrival gate to off-road destination pins.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_16_1100"
down_revision: str | Sequence[str] | None = "2026_11_16_1000"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "destinations",
        sa.Column("access_trail_polyline", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("destinations", "access_trail_polyline")
